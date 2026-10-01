// Copyright 2026 KoukeNeko
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Citadel
import Crypto
import Foundation
import NIOCore
import NIOSSH

/// SFTP implementation of RemoteFileService, built on Citadel (SwiftNIO SSH).
///
/// An actor so access to the underlying connection is serialized; one
/// instance corresponds to one SSH connection.
public actor SFTPFileService: RemoteFileService {
    // POSIX file-type bits (the S_IFMT segment of st_mode), used to derive
    // the item kind from the permissions field.
    private static let fileTypeMask: UInt32 = 0o170000
    private static let directoryTypeBits: UInt32 = 0o040000
    private static let symlinkTypeBits: UInt32 = 0o120000

    /// Bytes requested per SFTP read. Kept at 32 KiB because a single read
    /// has to fit in one SSH channel packet; larger requests stall.
    private static let transferChunkSize = 32 * 1024

    /// Bytes per SFTP write. Citadel splits anything larger at 32,000 bytes
    /// (NIOSSH issue 99), so a bigger chunk would just become two round
    /// trips in a row.
    private static let uploadChunkSize = 32_000

    /// Requests kept in flight during a transfer. One request per round trip
    /// caps a transfer at chunk size / RTT (about 640 KB/s at 50 ms); a
    /// window of them fills the pipe instead.
    private static let transferWindow = 32

    /// A directory listing is many round trips inside one call, so its idle
    /// budget is a multiple of the single-request one.
    private static let listingTimeoutFactor = 4

    private static let log = HamasenLog(category: "sftp")

    private let config: ServerConfig
    private let credentials: ServerCredentials
    private let connectTimeoutSeconds: Int
    private let hostKeyPolicy: HostKeyPolicy
    private var session: Session?

    public init(
        config: ServerConfig,
        credentials: ServerCredentials,
        connectTimeoutSeconds: Int = AppSettings.defaultConnectTimeoutSeconds,
        hostKeyPolicy: HostKeyPolicy
    ) {
        self.config = config
        self.credentials = credentials
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.hostKeyPolicy = hostKeyPolicy
    }

    // MARK: - Connection lifecycle

    public func connect() async throws {
        guard session == nil else { return }

        Self.log.debug("Connecting to \(config.host):\(config.port) as \(config.username)")
        // Built before the do/catch so an unusable key reports its own
        // reason instead of being flattened into a connection failure.
        let authenticationMethod = try makeAuthenticationMethod()

        let client: SSHClient
        do {
            client = try await SSHClient.connect(
                host: config.host,
                port: config.port,
                authenticationMethod: authenticationMethod,
                hostKeyValidator: hostKeyPolicy.makeValidator(
                    endpoint: config.hostKeyEndpoint,
                    log: Self.log
                ),
                reconnect: .never,
                connectTimeout: .seconds(Int64(connectTimeoutSeconds))
            )
        } catch let error as RemoteFileServiceError {
            // A refused host key already says exactly what happened; wrapping
            // it as a connection failure would throw that away.
            Self.log.error("SSH connection to \(config.host):\(config.port) refused: \(String(describing: error))")
            throw error
        } catch SSHClientError.allAuthenticationOptionsFailed {
            // The server answered and turned the password or key down, which
            // is a question for the person, not a server that is down.
            Self.log.error("SSH authentication to \(config.host):\(config.port) as \(config.username) was refused")
            throw RemoteFileServiceError.authenticationFailed
        } catch {
            Self.log.error("SSH connection to \(config.host):\(config.port) failed: \(String(describing: error))")
            throw RemoteFileServiceError.connectionFailed(underlying: String(describing: error))
        }

        do {
            session = Session(
                ssh: client,
                sftp: try await client.openSFTP(),
                requestTimeoutSeconds: connectTimeoutSeconds
            )
            Self.log.debug("SFTP session established with \(config.host)")
        } catch {
            Self.log.error("Opening SFTP subsystem on \(config.host) failed: \(String(describing: error))")
            try? await client.close()
            throw RemoteFileServiceError.connectionFailed(underlying: String(describing: error))
        }
    }

    /// The SSH channel's own view of itself: the server closing the session
    /// takes the channel down, which is visible here without a round trip.
    /// A request that timed out has also written the session off, since a
    /// half-open connection still looks active to the channel.
    public var isConnected: Bool {
        session?.isUsable ?? false
    }

    public func disconnect() async throws {
        let sftp = session?.sftp
        let ssh = session?.ssh
        session = nil
        // Started rather than awaited. A peer that has gone away never
        // answers the close handshake, and this service already considers
        // itself disconnected, so there is nothing left for the caller to
        // wait for — while waiting would hang an eviction sweep, or a
        // registry replacing a dead session, for as long as the process
        // lives. The task suspends on the actor rather than holding it, so
        // one that never finishes costs a connection, not the service.
        Task {
            try? await sftp?.close()
            try? await ssh?.close()
        }
    }

    // MARK: - RemoteFileService

    public func listDirectory(at path: String) async throws -> [RemoteItem] {
        try await listEntries(at: path, resolvingLinks: true)
    }

    /// Lists a directory, with each symlink either reported as what it points
    /// at (`resolvingLinks`, the view everything but deletion wants) or left
    /// as the link it is.
    public func listDirectoryWithoutFollowingLinks(at path: String) async throws -> [RemoteItem] {
        try await listEntries(at: path, resolvingLinks: false)
    }

    /// `includingUnfinishedUploads` is for deleting a folder: an upload cut
    /// off with its connection leaves its temporary file behind, and RMDIR
    /// refuses a folder until that is gone too.
    private func listEntries(
        at path: String, resolvingLinks: Bool, includingUnfinishedUploads: Bool = false
    ) async throws -> [RemoteItem] {
        let session = try activeSession()
        let remoteDirectory = remoteAbsolutePath(for: path)
        let sftp = session.sftp

        let nameBatches: [SFTPMessage.Name]
        do {
            nameBatches = try await session.run(timeoutSeconds: session.requestTimeoutSeconds * Self.listingTimeoutFactor) {
                try await sftp.listDirectory(atPath: remoteDirectory)
            }
        } catch {
            throw session.mapError(error, operation: String(localized: "列出目錄", bundle: .module), path: path)
        }

        var items: [RemoteItem] = []
        for component in nameBatches.flatMap(\.components)
        where component.filename != "." && component.filename != ".."
            && (includingUnfinishedUploads || !RemotePath.isTemporaryUpload(name: component.filename)) {
            let item = Self.makeRemoteItem(
                path: RemotePath.join(path, component.filename),
                name: component.filename,
                attributes: component.attributes
            )
            items.append(resolvingLinks && item.kind == .symlink ? await resolvingLink(item, session: session) : item)
        }
        return items
    }

    /// Reports a symlink as whatever it points at.
    ///
    /// Listing a directory describes each entry itself, so a symlink is a
    /// symlink; asking about one path follows the link, so the same entry is
    /// a directory. The system compares the two, finds a file that is a
    /// symlink here and a directory there, and retries that reconciliation
    /// for as long as the item exists — a `.bun` cache full of them kept
    /// fileproviderd's database busy until the daemon gave up and exited,
    /// taking this extension with it.
    ///
    /// Following is also what the person browsing expects: a link to a
    /// folder opens, a link to a file downloads. One extra request per
    /// symlink, and only for symlinks. A link that points nowhere stays a
    /// symlink, which is what it is.
    private func resolvingLink(_ item: RemoteItem, session: Session) async -> RemoteItem {
        let sftp = session.sftp
        let linkPath = remoteAbsolutePath(for: item.path)
        guard let target = try? await session.run({ try await sftp.getAttributes(at: linkPath) }) else {
            return item
        }
        return Self.makeRemoteItem(path: item.path, name: item.name, attributes: target, isResolvedLink: true)
    }

    public func itemInfo(at path: String) async throws -> RemoteItem {
        let session = try activeSession()
        let sftp = session.sftp
        let remotePath = remoteAbsolutePath(for: path)
        do {
            let attributes = try await session.run { try await sftp.getAttributes(at: remotePath) }
            return Self.makeRemoteItem(path: path, name: RemotePath.name(of: path), attributes: attributes)
        } catch {
            throw session.mapError(error, operation: String(localized: "讀取屬性", bundle: .module), path: path)
        }
    }

    public func downloadFile(at path: String, to localURL: URL, progress: TransferProgress?) async throws {
        let session = try activeSession()

        // Streamed in chunks straight to disk: a whole file never has to fit
        // in memory.
        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        let localFile: FileHandle
        do {
            localFile = try FileHandle(forWritingTo: localURL)
        } catch {
            throw RemoteFileServiceError.localFileUnreadable(url: localURL)
        }
        defer { try? localFile.close() }

        do {
            try await withOpenFile(session: session, path: remoteAbsolutePath(for: path), flags: .read) { file in
                var written: Int64 = 0
                try await Self.readPipelined(file: file, session: session, from: 0, upTo: nil) { chunk in
                    try localFile.write(contentsOf: chunk)
                    written += Int64(chunk.count)
                    progress?(written)
                }
            }
        } catch {
            throw session.mapError(error, operation: String(localized: "下載", bundle: .module), path: path)
        }
    }

    public func downloadRange(at path: String, offset: Int64, length: Int) async throws -> Data {
        let session = try activeSession()
        guard length > 0 else { return Data() }

        do {
            return try await withOpenFile(session: session, path: remoteAbsolutePath(for: path), flags: .read) { file in
                var collected = Data()
                collected.reserveCapacity(length)
                try await Self.readPipelined(
                    file: file,
                    session: session,
                    from: UInt64(offset),
                    upTo: UInt64(offset) + UInt64(length)
                ) { collected.append($0) }
                return collected
            }
        } catch {
            throw session.mapError(error, operation: String(localized: "下載區間", bundle: .module), path: path)
        }
    }

    public func uploadFile(from localURL: URL, to path: String, progress: TransferProgress?) async throws {
        let session = try activeSession()

        let localFile: FileHandle
        do {
            localFile = try FileHandle(forReadingFrom: localURL)
        } catch {
            throw RemoteFileServiceError.localFileUnreadable(url: localURL)
        }
        defer { try? localFile.close() }

        // Written beside the destination and renamed over it, so a
        // connection lost halfway leaves the old file (or nothing) under the
        // real name instead of half a new one.
        let destination = remoteAbsolutePath(for: path)
        let temporary = RemotePath.temporaryUploadPath(for: destination)
        let operation = String(localized: "上傳", bundle: .module)

        do {
            try await withOpenFile(session: session, path: temporary, flags: [.write, .create, .truncate]) { file in
                try await Self.writePipelined(
                    file: file,
                    session: session,
                    from: localFile,
                    localURL: localURL,
                    progress: progress
                )
            }
            try await replace(destination, with: temporary, session: session)
        } catch let incomplete as ReplaceIncomplete {
            // The old file is gone and the upload is the only copy left on
            // the server, so it stays under its temporary name, where the
            // next listing hides it but nothing removes it.
            Self.log.error(
                "Upload of \(path) could not be renamed into place and the old file could not be put back; "
                + "the new content is at \(temporary), the old at \(incomplete.oldFileAt): "
                + "\(String(describing: incomplete.underlying))")
            throw session.mapError(incomplete.underlying, operation: operation, path: path)
        } catch {
            await removeTemporaryUpload(temporary, session: session)
            throw session.mapError(error, operation: operation, path: path)
        }
    }

    /// Thrown once the destination has been moved aside and the upload could
    /// neither take its place nor the old file be put back.
    private struct ReplaceIncomplete: Error {
        let underlying: Error
        let oldFileAt: String
    }

    /// Renames the upload over the destination.
    ///
    /// Citadel offers no `posix-rename@openssh.com`, which would overwrite
    /// atomically; a plain SFTP rename refuses an existing destination on
    /// most servers, and removing the old file first would leave a window in
    /// which a failure loses both versions. So the old file is moved aside instead,
    /// and only removed once the upload is in place; if the upload cannot be
    /// renamed, the old file is put back.
    private func replace(_ destination: String, with temporary: String, session: Session) async throws {
        let sftp = session.sftp
        do {
            try await session.run { try await sftp.rename(at: temporary, to: destination) }
            return
        } catch {
            guard await itemExists(destination, session: session) else { throw error }
        }

        let backup = RemotePath.temporaryUploadPath(for: destination)
        try await session.run { try await sftp.rename(at: destination, to: backup) }
        // Checked on what was moved, not before the move, so nothing can
        // change it in between. A directory put there by someone else during
        // the upload is not a file to replace — and SFTP could not remove it
        // afterwards — so it goes back and the upload fails.
        guard await entryKind(at: backup, session: session) == .file else {
            do {
                try await session.run { try await sftp.rename(at: backup, to: destination) }
            } catch {
                throw ReplaceIncomplete(underlying: error, oldFileAt: backup)
            }
            throw RemoteFileServiceError.alreadyExists(path: destination)
        }
        do {
            try await session.run { try await sftp.rename(at: temporary, to: destination) }
        } catch {
            do {
                try await session.run { try await sftp.rename(at: backup, to: destination) }
            } catch {
                throw ReplaceIncomplete(underlying: error, oldFileAt: backup)
            }
            throw error
        }
        await removeTemporaryUpload(backup, session: session)
    }

    private func removeTemporaryUpload(_ temporary: String, session: Session) async {
        let sftp = session.sftp
        do {
            try await session.run { try await sftp.remove(at: temporary) }
        } catch let status as SFTPMessage.Status where status.errorCode == .noSuchFile {
            // Never created, or already renamed into place.
        } catch {
            Self.log.error("Removing unfinished upload \(temporary) failed: \(String(describing: error))")
        }
    }

    /// The kind of the entry at a path, links not followed; nil when it
    /// cannot be told.
    private func entryKind(at remotePath: String, session: Session) async -> RemoteItem.Kind? {
        let parent = RemotePath.parent(of: remotePath)
        let name = RemotePath.name(of: remotePath)
        let sftp = session.sftp
        guard let batches = try? await session.run({ try await sftp.listDirectory(atPath: parent) }) else {
            return nil
        }
        for batch in batches {
            for component in batch.components where component.filename == name {
                return Self.kind(fromPermissions: component.attributes.permissions)
            }
        }
        return nil
    }

    /// Whether a path exists, as far as the server says. Citadel's test
    /// server answers a stat of a missing path with empty attributes rather
    /// than an error, and a real server always includes the mode, so a
    /// missing mode counts as missing.
    private func itemExists(_ remotePath: String, session: Session) async -> Bool {
        let sftp = session.sftp
        guard let attributes = try? await session.run({ try await sftp.getAttributes(at: remotePath) }) else {
            return false
        }
        return attributes.permissions != nil
    }

    public func createDirectory(at path: String) async throws {
        let session = try activeSession()
        let sftp = session.sftp
        let remotePath = remoteAbsolutePath(for: path)
        do {
            try await session.run { try await sftp.createDirectory(atPath: remotePath) }
        } catch {
            // As with a rename, an existing name comes back as the same
            // generic failure as anything else.
            if let status = error as? SFTPMessage.Status, status.errorCode == .failure,
               await itemExists(remotePath, session: session) {
                throw RemoteFileServiceError.alreadyExists(path: path)
            }
            throw session.mapError(error, operation: String(localized: "建立目錄", bundle: .module), path: path)
        }
    }

    public func deleteFile(at path: String) async throws {
        let session = try activeSession()
        let sftp = session.sftp
        let remotePath = remoteAbsolutePath(for: path)
        do {
            try await session.run { try await sftp.remove(at: remotePath) }
        } catch {
            throw session.mapError(error, operation: String(localized: "刪除檔案", bundle: .module), path: path)
        }
    }

    public func deleteDirectory(at path: String) async throws {
        // Listings and stat report a symlink as its target, so a link to a
        // directory arrives here looking like a directory. Walking into it
        // would delete the target's contents; the link alone is what was
        // asked for.
        if try await isSymlink(at: path) {
            try await deleteFile(at: path)
            return
        }
        try await deleteTree(at: path)
    }

    /// Whether the path itself is a symlink. Citadel has no lstat, but a
    /// directory listing describes each entry without following it.
    private func isSymlink(at path: String) async throws -> Bool {
        let parent = RemotePath.parent(of: path)
        guard parent != path else { return false }
        let name = RemotePath.name(of: path)
        return try await listEntries(at: parent, resolvingLinks: false)
            .contains { $0.name == name && $0.kind == .symlink }
    }

    private func deleteTree(at path: String) async throws {
        // SFTP's RMDIR only removes an empty directory, so the tree is
        // emptied depth-first first. Only a real directory is entered: a
        // link, whatever it points at, is removed as a link.
        for child in try await listEntries(at: path, resolvingLinks: false, includingUnfinishedUploads: true) {
            if child.kind == .directory {
                try await deleteTree(at: child.path)
            } else {
                try await deleteFile(at: child.path)
            }
        }

        let session = try activeSession()
        let sftp = session.sftp
        let remotePath = remoteAbsolutePath(for: path)
        do {
            try await session.run { try await sftp.rmdir(at: remotePath) }
        } catch {
            throw session.mapError(error, operation: String(localized: "刪除目錄", bundle: .module), path: path)
        }
    }

    public func moveItem(from oldPath: String, to newPath: String) async throws {
        let session = try activeSession()
        let sftp = session.sftp
        let source = remoteAbsolutePath(for: oldPath)
        let destination = remoteAbsolutePath(for: newPath)
        do {
            try await session.run { try await sftp.rename(at: source, to: destination) }
        } catch {
            // A plain rename refuses an existing destination with the same
            // generic failure as anything else; only asking tells them apart.
            if let status = error as? SFTPMessage.Status, status.errorCode == .failure,
               await itemExists(destination, session: session) {
                throw RemoteFileServiceError.alreadyExists(path: newPath)
            }
            throw session.mapError(error, operation: String(localized: "移動", bundle: .module), path: oldPath)
        }
    }

    // MARK: - Transfers

    /// An open remote file, passed between the tasks of one transfer. Citadel's
    /// class is not marked Sendable; every request on it is already
    /// serialized through the channel's event loop.
    private struct OpenFile: @unchecked Sendable {
        let file: SFTPFile
    }

    private func withOpenFile<T>(
        session: Session,
        path: String,
        flags: SFTPOpenFileFlags,
        _ body: (OpenFile) async throws -> T
    ) async throws -> T {
        let sftp = session.sftp
        let file = try await session.run {
            OpenFile(file: try await sftp.openFile(filePath: path, flags: flags))
        }

        let result: T
        do {
            result = try await body(file)
        } catch {
            // The failure that matters is the body's; a close that also
            // fails on a broken connection adds nothing.
            _ = try? await session.run { try await file.file.close() }
            throw error
        }
        // A failed close on a written file can mean the data was not kept.
        try await session.run { try await file.file.close() }
        return result
    }

    /// Reads `[start, end)` (to end of file when `end` is nil) with a window
    /// of requests in flight, handing the bytes to `consume` in order.
    ///
    /// Requests are issued at fixed offsets ahead of time, so a server that
    /// answers a read with fewer bytes than asked leaves a hole; the gap is
    /// re-requested before anything after it is used.
    private static func readPipelined(
        file: OpenFile,
        session: Session,
        from start: UInt64,
        upTo end: UInt64?,
        consume: (Data) throws -> Void
    ) async throws {
        let chunkSize = UInt64(transferChunkSize)

        func requestLength(at offset: UInt64) -> UInt64 {
            guard let end else { return chunkSize }
            return offset >= end ? 0 : min(chunkSize, end - offset)
        }

        func read(at offset: UInt64, length: UInt64) async throws -> Data {
            let buffer = try await session.run { try await file.file.read(from: offset, length: UInt32(length)) }
            return Data(buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) ?? [])
        }

        try await withThrowingTaskGroup(of: (index: UInt64, data: Data).self) { group in
            var nextToLaunch: UInt64 = 0
            var nextToConsume: UInt64 = 0
            var arrived: [UInt64: Data] = [:]
            var reachedEnd = false

            func launchWhileRoom() {
                while !reachedEnd, nextToLaunch - nextToConsume < UInt64(transferWindow) {
                    let index = nextToLaunch
                    let offset = start + index * chunkSize
                    let length = requestLength(at: offset)
                    guard length > 0 else { return }
                    nextToLaunch += 1
                    group.addTask { (index, try await read(at: offset, length: length)) }
                }
            }

            launchWhileRoom()
            while let (index, data) = try await group.next() {
                try Task.checkCancellation()
                // Past the end of the file: only draining what was in flight.
                if reachedEnd { continue }
                arrived[index] = data

                while var chunk = arrived.removeValue(forKey: nextToConsume) {
                    let offset = start + nextToConsume * chunkSize
                    let wanted = Int(requestLength(at: offset))
                    while !chunk.isEmpty, chunk.count < wanted {
                        let more = try await read(
                            at: offset + UInt64(chunk.count),
                            length: UInt64(wanted - chunk.count)
                        )
                        if more.isEmpty { break }
                        chunk.append(more)
                    }
                    if !chunk.isEmpty { try consume(chunk) }
                    nextToConsume += 1
                    // A chunk that is still short after re-asking is the end
                    // of the file; whatever was requested beyond it is empty.
                    if chunk.count < wanted { reachedEnd = true }
                }
                launchWhileRoom()
                if reachedEnd { group.cancelAll() }
            }
        }
    }

    /// Streams a local file to the remote one with a window of writes in
    /// flight. Progress counts bytes the server has acknowledged.
    private static func writePipelined(
        file: OpenFile,
        session: Session,
        from localFile: FileHandle,
        localURL: URL,
        progress: TransferProgress?
    ) async throws {
        try await withThrowingTaskGroup(of: Int.self) { group in
            var offset: UInt64 = 0
            var inFlight = 0
            var acknowledged: Int64 = 0

            func settleOne() async throws {
                guard let count = try await group.next() else { return }
                inFlight -= 1
                acknowledged += Int64(count)
                progress?(acknowledged)
            }

            while true {
                try Task.checkCancellation()
                let chunk: Data
                do {
                    guard let read = try localFile.read(upToCount: uploadChunkSize), !read.isEmpty else { break }
                    chunk = read
                } catch {
                    throw RemoteFileServiceError.localFileUnreadable(url: localURL)
                }

                if inFlight >= transferWindow { try await settleOne() }
                let chunkOffset = offset
                offset += UInt64(chunk.count)
                inFlight += 1
                group.addTask {
                    try await session.run {
                        try await file.file.write(ByteBuffer(data: chunk), at: chunkOffset)
                    }
                    return chunk.count
                }
            }
            while inFlight > 0 { try await settleOne() }
        }
    }

    // MARK: - Session

    /// One SSH connection and its SFTP channel, plus what it takes to notice
    /// that the connection has died without saying so.
    ///
    /// Apart from the SFTP setup, Citadel puts no timeout on anything: over a
    /// half-open TCP connection a request waits forever and the channel still
    /// reports itself active, which would hang every caller behind a session
    /// the registry believes is healthy.
    private final class Session: @unchecked Sendable {
        let ssh: SSHClient
        let sftp: SFTPClient
        /// How long a single round trip may go unanswered. A transfer is many
        /// round trips, so a large file is never cut off for being large.
        let requestTimeoutSeconds: Int

        private let lock = NSLock()
        private var isDead = false

        init(ssh: SSHClient, sftp: SFTPClient, requestTimeoutSeconds: Int) {
            self.ssh = ssh
            self.sftp = sftp
            self.requestTimeoutSeconds = requestTimeoutSeconds
        }

        var isUsable: Bool {
            lock.withLock { !isDead } && sftp.isActive
        }

        /// Writes the session off and tears the channel down, which also
        /// fails every request still waiting on it. Not awaited, for the
        /// reason `disconnect` gives.
        func markDead() {
            let wasAlive = lock.withLock {
                defer { isDead = true }
                return !isDead
            }
            guard wasAlive else { return }
            let (sftp, ssh) = (sftp, ssh)
            Task {
                try? await sftp.close()
                try? await ssh.close()
            }
        }

        /// Runs one request, failing with a connection error (and writing
        /// the session off) if it is not answered in time.
        ///
        /// Cancellation does not answer the caller early: the request is
        /// already on the channel, and abandoning it lets its reply arrive
        /// after the session may have been closed, which NIOSSH treats as a
        /// fatal error. The transfer loops check cancellation between
        /// requests instead, so a cancelled transfer stops within one round
        /// trip — or the timeout, when the server has stopped answering.
        func run<T>(
            timeoutSeconds: Int? = nil,
            _ operation: @escaping @Sendable () async throws -> T
        ) async throws -> T {
            let seconds = timeoutSeconds ?? requestTimeoutSeconds
            let settled = SettleOnce()

            return try await withCheckedThrowingContinuation { continuation in
                let timer = Task {
                    do {
                        try await Task.sleep(for: .seconds(seconds))
                    } catch {
                        return
                    }
                    guard settled.claim() else { return }
                    SFTPFileService.log.error("SFTP request unanswered for \(seconds)s; dropping the session")
                    self.markDead()
                    continuation.resume(throwing: RemoteFileServiceError.connectionFailed(
                        underlying: "no response from server within \(seconds) seconds"
                    ))
                }
                Task {
                    do {
                        let value = try await operation()
                        if settled.claim() { continuation.resume(returning: value) }
                    } catch {
                        if settled.claim() { continuation.resume(throwing: error) }
                    }
                    timer.cancel()
                }
            }
        }

        /// Classifies a failure for the layers above, which treat a lost
        /// connection (pause and recover) differently from a refused
        /// operation (retry that one item).
        func mapError(_ error: Error, operation: String, path: String) -> Error {
            if error is CancellationError || error is RemoteFileServiceError { return error }

            var status = error as? SFTPMessage.Status
            if case .errorStatus(let wrapped)? = error as? SFTPError { status = wrapped }

            if let status {
                switch status.errorCode {
                case .noSuchFile:
                    SFTPFileService.log.debug("\(operation) at \(path): no such file")
                    return RemoteFileServiceError.itemNotFound(path: path)
                case .permissionDenied:
                    SFTPFileService.log.debug("\(operation) at \(path): permission denied")
                    return RemoteFileServiceError.permissionDenied(operation: operation, path: path)
                case .noConnection, .connectionLost:
                    return connectionLost(error, operation: operation, path: path)
                default:
                    break
                }
            } else if Self.isConnectionLevel(error) || !sftp.isActive {
                return connectionLost(error, operation: operation, path: path)
            }

            SFTPFileService.log.error("\(operation) at \(path) failed: \(String(describing: error))")
            return RemoteFileServiceError.operationFailed(
                operation: operation,
                path: path,
                underlying: String(describing: error)
            )
        }

        private func connectionLost(_ error: Error, operation: String, path: String) -> Error {
            SFTPFileService.log.error("\(operation) at \(path) lost the connection: \(String(describing: error))")
            markDead()
            return RemoteFileServiceError.connectionFailed(underlying: String(describing: error))
        }

        private static func isConnectionLevel(_ error: Error) -> Bool {
            switch error {
            case let sftpError as SFTPError:
                switch sftpError {
                case .connectionClosed, .missingResponse: return true
                default: return false
                }
            case is ChannelError, is IOError, is NIOSSHError:
                return true
            default:
                return false
            }
        }
    }

    /// Lets exactly one of a request's answer and its timeout win.
    private final class SettleOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var settled = false

        func claim() -> Bool {
            lock.withLock {
                defer { settled = true }
                return !settled
            }
        }
    }

    // MARK: - Helpers

    private func activeSession() throws -> Session {
        guard let session else {
            throw RemoteFileServiceError.notConnected
        }
        return session
    }

    private func makeAuthenticationMethod() throws -> SSHAuthenticationMethod {
        switch credentials {
        case .password(let password):
            return .passwordBased(username: config.username, password: password)
        case .privateKey(let openSSHKey, let passphrase):
            return try Self.makeKeyAuthentication(
                openSSHKey: openSSHKey,
                passphrase: passphrase,
                username: config.username
            )
        }
    }

    /// Builds key-based authentication, dispatching on the key algorithm read
    /// from the file so the failure for an unusable key is reported before
    /// any network traffic.
    private static func makeKeyAuthentication(
        openSSHKey: String,
        passphrase: String?,
        username: String
    ) throws -> SSHAuthenticationMethod {
        let keyInfo = try OpenSSHPrivateKey.parse(openSSHKey)
        let decryptionKey = passphrase.map { Data($0.utf8) }
        guard !keyInfo.isEncrypted || decryptionKey != nil else {
            throw RemoteFileServiceError.privateKeyPassphraseRequired
        }

        do {
            switch keyInfo.keyType {
            case .ed25519:
                let privateKey = try Curve25519.Signing.PrivateKey(
                    sshEd25519: openSSHKey,
                    decryptionKey: decryptionKey
                )
                return .ed25519(username: username, privateKey: privateKey)
            case .rsa:
                let privateKey = try Insecure.RSA.PrivateKey(
                    sshRsa: openSSHKey,
                    decryptionKey: decryptionKey
                )
                return .rsa(username: username, privateKey: privateKey)
            }
        } catch {
            // The parser already validated the container, so a failure here
            // means the key material could not be decrypted.
            throw RemoteFileServiceError.privateKeyUnreadable(
                underlying: String(describing: error)
            )
        }
    }

    /// Maps a mount-relative path ("/docs/a.txt") to the remote absolute path
    /// (remotePath + relative path).
    private func remoteAbsolutePath(for mountRelativePath: String) -> String {
        RemotePath.resolve(mountRelativePath, against: config.remotePath)
    }

    private static func makeRemoteItem(
        path: String,
        name: String,
        attributes: SFTPFileAttributes,
        isResolvedLink: Bool = false
    ) -> RemoteItem {
        RemoteItem(
            path: path,
            name: name,
            kind: kind(fromPermissions: attributes.permissions),
            size: Int64(attributes.size ?? 0),
            modificationDate: attributes.accessModificationTime?.modificationTime,
            creationDate: nil,
            permissions: attributes.permissions.map { UInt16($0 & 0o7777) },
            isResolvedLink: isResolvedLink
        )
    }

    private static func kind(fromPermissions permissions: UInt32?) -> RemoteItem.Kind {
        guard let permissions else { return .file }
        switch permissions & fileTypeMask {
        case directoryTypeBits: return .directory
        case symlinkTypeBits: return .symlink
        default: return .file
        }
    }
}
