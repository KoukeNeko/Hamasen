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

import Foundation
import SMBClient

/// SMB 2/3 through SMBClient, a Swift implementation of the protocol.
///
/// An SMB connection is to one share, so the remote path's first component
/// names it — "/Public/Photos" mounts the Photos folder of the Public share —
/// the same way an S3 connection's names its bucket.
///
/// SMBClient sends one request at a time on a connection and matches each
/// response to it, so concurrent calls from the extension queue rather than
/// interleave; the actor only has to own the client's lifecycle.
public actor SMBFileService: RemoteFileService {
    private static let log = HamasenLog(category: "smb")

    /// A directory listing is many round trips inside one call, so its
    /// budget is a multiple of the single-request one, as SFTP's is.
    private static let listingTimeoutFactor = 4

    /// The most one transfer request carries. SMBClient tells nothing of a
    /// request until its whole answer is in, so a request is the smallest
    /// step of progress the deadline can see; at the size servers negotiate
    /// (8 MiB on Samba and Windows), one step over a slow but working link
    /// takes longer than the deadline allows.
    private static let transferChunkBytes = 1 << 20

    private let config: ServerConfig
    private let password: String?
    private let connectTimeoutSeconds: Int
    private var client: SMBClient?
    private var liveness: Liveness?
    private var isDisconnected = true

    public init(
        config: ServerConfig,
        credentials: ServerCredentials,
        connectTimeoutSeconds: Int = AppSettings.defaultConnectTimeoutSeconds
    ) {
        self.config = config
        if case .password(let password) = credentials {
            self.password = password
        } else {
            self.password = nil
        }
        self.connectTimeoutSeconds = connectTimeoutSeconds
    }

    // MARK: - Addressing

    /// The share and the folder inside it that the mount starts from.
    public struct Location: Equatable, Sendable {
        public let share: String
        public let directory: String
    }

    public static func location(of remotePath: String) -> Location? {
        let components = remotePath.split(separator: "/").map(String.init)
        guard let share = components.first, !share.isEmpty else { return nil }
        return Location(share: share, directory: components.dropFirst().joined(separator: "/"))
    }

    /// The path within the share, as SMB writes it: backslashes, no leading
    /// separator, "" for the share's top.
    static func sharePath(_ mountRelative: String, under directory: String) -> String {
        let parts = (directory.split(separator: "/") + mountRelative.split(separator: "/")).map(String.init)
        return parts.joined(separator: "\\")
    }

    /// "DOMAIN\user" as Windows writes it; NTLM wants the two apart.
    static func account(from username: String) -> (user: String, domain: String?) {
        if let slash = username.firstIndex(of: "\\") {
            return (String(username[username.index(after: slash)...]), String(username[..<slash]))
        }
        return (username, nil)
    }

    private func sharePath(_ path: String) throws -> String {
        guard let location = Self.location(of: config.remotePath) else {
            throw RemoteFileServiceError.connectionFailed(underlying: String(localized: "請在路徑填入共用資料夾名稱", bundle: .module))
        }
        return Self.sharePath(path, under: location.directory)
    }

    // MARK: - Connection

    public func connect() async throws {
        guard client == nil else { return }
        guard let password else {
            throw RemoteFileServiceError.unsupportedCredentials(protocolName: config.transferProtocol.displayName)
        }
        guard let location = Self.location(of: config.remotePath) else {
            throw RemoteFileServiceError.connectionFailed(underlying: String(localized: "請在路徑填入共用資料夾名稱", bundle: .module))
        }
        let candidate = SMBClient(host: config.host, port: config.port)
        let candidateLiveness = Liveness()
        let account = Self.account(from: config.username)
        Self.log.debug("Connecting to \(config.host):\(config.port) share \(location.share) as \(config.username)")
        do {
            try await answering(
                within: connectTimeoutSeconds, on: candidateLiveness, abandon: { candidate.session.disconnect() }
            ) {
                try await candidate.login(
                    username: account.user, password: password, domain: account.domain)
                try await candidate.connectShare(location.share)
            }
        } catch {
            candidate.session.disconnect()
            throw Self.mapped(error, operation: "connect", path: RemotePath.root)
        }
        candidate.onDisconnected = { [weak self] _ in
            Task { await self?.markDisconnected() }
        }
        client = candidate
        liveness = candidateLiveness
        isDisconnected = false
    }

    private func markDisconnected() {
        isDisconnected = true
    }

    public func disconnect() async throws {
        guard let client, let liveness else { return }
        let isKnownDead = isDisconnected
        self.client = nil
        self.liveness = nil
        isDisconnected = true
        // A logoff over a session already known dead would wait for an
        // answer that cannot come; closing the connection is all there is
        // left to do.
        guard !isKnownDead else {
            client.session.disconnect()
            return
        }
        // SMBClient closes the connection once the logoff is answered, and
        // the deadline closes it if no answer comes.
        _ = try? await answering(
            within: connectTimeoutSeconds, on: liveness, abandon: { client.session.disconnect() }
        ) {
            _ = try await client.logoff()
        }
    }

    public var isConnected: Bool { client != nil && !isDisconnected }

    public func checkReachable() async throws {
        _ = try await perform("echo", path: RemotePath.root) { client in
            try await client.keepAlive()
        }
    }

    /// The shares the server offers this account, for picking one before a
    /// connection is saved.
    public static func shares(
        host: String, port: Int, username: String, password: String,
        connectTimeoutSeconds: Int = AppSettings.defaultConnectTimeoutSeconds
    ) async throws -> [String] {
        let client = SMBClient(host: host, port: port)
        let account = account(from: username)
        do {
            return try await answering(
                within: connectTimeoutSeconds, on: Liveness(), abandon: { client.session.disconnect() }
            ) {
                try await client.login(username: account.user, password: password, domain: account.domain)
                let shares = try await client.listShares()
                _ = try? await client.logoff()
                // Administrative shares (C$, IPC$) are not folders anyone
                // means to mount.
                return shares.map(\.name).filter { !$0.hasSuffix("$") }.sorted()
            }
        } catch {
            client.session.disconnect()
            throw mapped(error, operation: "connect", path: RemotePath.root)
        }
    }

    // MARK: - Listing

    public func listDirectory(at path: String) async throws -> [RemoteItem] {
        let smbPath = try sharePath(path)
        let files = try await perform("list", path: path, timeoutFactor: Self.listingTimeoutFactor) { client in
            try await client.listDirectory(path: smbPath)
        }
        return files.compactMap { file in
            guard file.name != ".", file.name != "..",
                  // $RECYCLE.BIN, System Volume Information: Windows hides
                  // these from everyone, and so does this.
                  !(file.isHidden && file.isSystem),
                  !RemotePath.isTemporaryUpload(name: file.name)
            else { return nil }
            return RemoteItem(
                path: RemotePath.join(path, file.name),
                name: file.name,
                kind: file.isDirectory ? .directory : .file,
                size: file.isDirectory ? 0 : Int64(file.size),
                modificationDate: file.lastWriteTime,
                creationDate: file.creationTime,
                permissions: file.isReadOnly && !file.isDirectory ? 0o444 : nil)
        }
    }

    public func itemInfo(at path: String) async throws -> RemoteItem {
        let smbPath = try sharePath(path)
        let stat = try await perform("stat", path: path) { client in
            try await client.fileStat(path: smbPath)
        }
        return RemoteItem(
            path: path,
            name: path == RemotePath.root ? RemotePath.root : RemotePath.name(of: path),
            kind: stat.isDirectory ? .directory : .file,
            size: stat.isDirectory ? 0 : Int64(stat.size),
            modificationDate: stat.lastWriteTime,
            creationDate: stat.creationTime,
            permissions: stat.isReadOnly && !stat.isDirectory ? 0o444 : nil)
    }

    // MARK: - Transfers

    public func downloadFile(at path: String, to localURL: URL, progress: TransferProgress?) async throws {
        let smbPath = try sharePath(path)
        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: localURL)
        defer { try? output.close() }
        try await perform("download", path: path) { client, liveness in
            let reader = client.fileReader(path: smbPath)
            do {
                let size = try await reader.fileSize
                var offset: UInt64 = 0
                while offset < size {
                    try Task.checkCancellation()
                    let chunk = try await reader.read(offset: offset, length: UInt32(Self.transferChunkBytes))
                    if chunk.isEmpty { break }
                    liveness.touch()
                    try output.write(contentsOf: chunk)
                    offset += UInt64(chunk.count)
                    progress?(Int64(offset))
                }
                try await reader.close()
            } catch {
                try? await reader.close()
                throw error
            }
        }
    }

    public func downloadRange(at path: String, offset: Int64, length: Int) async throws -> Data {
        guard length > 0 else { return Data() }
        let smbPath = try sharePath(path)
        return try await perform("download", path: path) { client, liveness in
            let reader = client.fileReader(path: smbPath)
            do {
                let size = try await reader.fileSize
                var position = UInt64(offset)
                let end = min(UInt64(offset) + UInt64(length), size)
                var data = Data()
                while position < end {
                    try Task.checkCancellation()
                    // A chunk at a time, so progress shows on the deadline as
                    // it comes: given the whole range, SMBClient's read would
                    // gather all of it before returning.
                    let chunk = try await reader.read(
                        offset: position, length: UInt32(min(end - position, UInt64(Self.transferChunkBytes))))
                    if chunk.isEmpty { break }
                    liveness.touch()
                    data.append(chunk)
                    position += UInt64(chunk.count)
                }
                try await reader.close()
                return data
            } catch {
                try? await reader.close()
                throw error
            }
        }
    }

    /// Written beside the file and moved over it once complete, so a
    /// dropped connection never leaves half a file under the real name.
    public func uploadFile(from localURL: URL, to path: String, progress: TransferProgress?) async throws {
        guard let input = try? FileHandle(forReadingFrom: localURL) else {
            throw RemoteFileServiceError.localFileUnreadable(url: localURL)
        }
        defer { try? input.close() }
        let temporaryPath = RemotePath.temporaryUploadPath(for: path)
        let temporary = try sharePath(temporaryPath)
        let destination = try sharePath(path)
        let backup = try sharePath(RemotePath.temporaryUploadPath(for: path))

        do {
            // Written through the session rather than SMBClient's FileWriter,
            // which sends each write at the negotiated maximum size; the file
            // is created as FileWriter creates it.
            try await perform("upload", path: path) { client, liveness in
                let session = client.session
                let file = try await session.create(
                    desiredAccess: [.readData, .writeData, .appendData, .readAttributes, .readControl, .writeDac],
                    fileAttributes: [.archive, .normal],
                    shareAccess: [.read, .write, .delete],
                    createDisposition: .create,
                    createOptions: [],
                    name: temporary.precomposedStringWithCanonicalMapping)
                do {
                    // A server allows no write larger than it negotiated:
                    // 64 KiB on one that speaks only SMB 2.0.2.
                    let chunkSize = min(Self.transferChunkBytes, Int(session.maxWriteSize))
                    var offset: UInt64 = 0
                    while let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty {
                        try Task.checkCancellation()
                        try await session.write(
                            data: chunk, fileId: file.fileId, offset: offset, length: UInt32(chunk.count))
                        liveness.touch()
                        offset += UInt64(chunk.count)
                        progress?(Int64(offset))
                    }
                    try await session.close(fileId: file.fileId)
                } catch {
                    _ = try? await session.close(fileId: file.fileId)
                    throw error
                }
            }
        } catch {
            _ = try? await perform("delete", path: temporaryPath) { client in
                try await client.deleteFile(path: temporary)
            }
            throw error
        }
        try await perform("upload", path: path) { client in
            try await Self.replace(destination, with: temporary, aside: backup, on: client)
        }
    }

    /// Puts the upload at `temporary` in the place of `destination`, or
    /// leaves the destination as it was and removes the upload.
    ///
    /// SMB renames onto an existing name only when asked to replace it, which
    /// SMBClient's move does not ask, and deleting the old file first would
    /// leave a window in which a failure loses both versions. So the old file
    /// is moved aside to `backup`, a name listings hide and recursive deletes
    /// remove, and deleted only once the upload has taken its place; if the
    /// upload cannot, the old file is put back.
    static func replace(
        _ destination: String, with temporary: String, aside backup: String, on client: some SMBReplacing
    ) async throws {
        let refusal: ErrorResponse
        do {
            try await client.move(from: temporary, to: destination)
            return
        } catch let error as ErrorResponse where NTStatus(error.header.status) == .objectNameCollision {
            refusal = error
        } catch {
            await remove(temporary, on: client)
            throw error
        }

        do {
            try await client.move(from: destination, to: backup)
        } catch {
            await remove(temporary, on: client)
            throw error
        }
        do {
            // Checked on what was moved, so nothing can change it in between.
            // A folder put there by someone else during the upload is not a
            // file to replace, so it goes back and the upload fails as the
            // rename did.
            if try await client.existDirectory(path: backup) { throw refusal }
            try await client.move(from: temporary, to: destination)
        } catch {
            do {
                try await client.move(from: backup, to: destination)
            } catch let restoring {
                // Both versions are only under hidden names now, so neither
                // is removed: what is left there is for someone to recover.
                log.error(
                    "Upload to \(destination) could not take the old file's place, nor the old file be put back; "
                    + "the new content is at \(temporary), the old at \(backup): "
                    + "\(String(describing: error)); \(String(describing: restoring))")
                throw error
            }
            await remove(temporary, on: client)
            throw error
        }
        await remove(backup, on: client)
    }

    /// Best effort: whatever is left stays under a hidden name, which
    /// listings leave out and a recursive delete removes.
    private static func remove(_ path: String, on client: some SMBReplacing) async {
        do {
            try await client.deleteFile(path: path)
        } catch {
            log.notice("Could not remove \(path): \(String(describing: error))")
        }
    }

    // MARK: - Changes

    public func createDirectory(at path: String) async throws {
        let smbPath = try sharePath(path)
        try await perform("mkdir", path: path) { client in
            try await client.createDirectory(path: smbPath)
        }
    }

    public func deleteFile(at path: String) async throws {
        let smbPath = try sharePath(path)
        try await perform("delete", path: path) { client in
            try await client.deleteFile(path: smbPath)
        }
    }

    /// Walked here, files before their folders, rather than by SMBClient's
    /// own recursive delete, so that each request has a deadline of its own:
    /// one deadline for the whole tree would cut off a large folder for
    /// being large.
    public func deleteDirectory(at path: String) async throws {
        let smbPath = try sharePath(path)
        let children = try await perform("delete", path: path, timeoutFactor: Self.listingTimeoutFactor) { client in
            try await client.listDirectory(path: smbPath)
        }
        for child in children where child.name != "." && child.name != ".." {
            let childPath = RemotePath.join(path, child.name)
            if child.isDirectory {
                try await deleteDirectory(at: childPath)
            } else {
                try await deleteFile(at: childPath)
            }
        }
        try await perform("delete", path: path) { client in
            try await client.deleteDirectory(path: smbPath)
        }
    }

    public func moveItem(from oldPath: String, to newPath: String) async throws {
        let source = try sharePath(oldPath)
        let destination = try sharePath(newPath)
        try await perform("move", path: oldPath, destination: newPath) { client in
            try await client.move(from: source, to: destination)
        }
    }

    // MARK: - Running requests

    private func perform<T>(
        _ operation: String, path: String, destination: String? = nil, timeoutFactor: Int = 1,
        _ work: @escaping @Sendable (SMBClient) async throws -> T
    ) async throws -> T {
        try await perform(operation, path: path, destination: destination, timeoutFactor: timeoutFactor) { client, _ in
            try await work(client)
        }
    }

    /// Runs requests on the session with a deadline: SMBClient puts none on
    /// a request, so without one, an answer that never comes over a
    /// connection that stopped carrying anything is waited for as long as
    /// the process lives. The deadline is on the session's silence, not on
    /// the call's length — a transfer touches `Liveness` as each piece
    /// completes, and every call answered counts for the calls queued behind
    /// it — so work that keeps moving is never cut off. Running out writes
    /// the session off.
    private func perform<T>(
        _ operation: String, path: String, destination: String? = nil, timeoutFactor: Int = 1,
        _ work: @escaping @Sendable (SMBClient, Liveness) async throws -> T
    ) async throws -> T {
        guard let client, let liveness, !isDisconnected else { throw RemoteFileServiceError.notConnected }
        do {
            return try await answering(
                within: connectTimeoutSeconds * timeoutFactor, on: liveness,
                abandon: { client.session.disconnect() }
            ) {
                try await work(client, liveness)
            }
        } catch {
            let mapped = Self.mapped(error, operation: operation, path: path, destination: destination)
            if case RemoteFileServiceError.connectionFailed = mapped { isDisconnected = true }
            throw mapped
        }
    }

    static func mapped(
        _ error: Error, operation: String, path: String, destination: String? = nil
    ) -> Error {
        if error is CancellationError || error is RemoteFileServiceError { return error }
        if let response = error as? ErrorResponse {
            switch NTStatus(response.header.status) {
            case .objectNameNotFound, .objectPathNotFound, .noSuchFile:
                return RemoteFileServiceError.itemNotFound(path: path)
            case .objectNameCollision:
                return RemoteFileServiceError.alreadyExists(path: destination ?? path)
            case .accessDenied:
                return RemoteFileServiceError.permissionDenied(operation: operation, path: path)
            case .logonFailure:
                return RemoteFileServiceError.authenticationFailed
            default:
                return RemoteFileServiceError.operationFailed(
                    operation: operation, path: path, underlying: response.localizedDescription)
            }
        }
        // Everything else came from the transport: a refused or dropped TCP
        // connection, or the connect timeout.
        return RemoteFileServiceError.connectionFailed(underlying: error.localizedDescription)
    }
}

/// Answers with a timeout once the session `liveness` watches has gone
/// `seconds` without a sign of life, whether or not `work` has returned.
///
/// SMBClient does not stop for cancellation either: a request waits on its
/// connection until an answer or an error arrives. Waiting for it to give
/// up, as a task group does for its children, would wait with it. So the
/// caller is answered at the deadline, and `abandon` closes the connection,
/// which is what ends the request still waiting on it.
func answering<T>(
    within seconds: Int,
    on liveness: Liveness,
    abandon: @escaping @Sendable () -> Void,
    _ work: @escaping @Sendable () async throws -> T
) async throws -> T {
    let allowance = Duration.seconds(seconds)
    let answer = Answer()
    let worker = Worker()
    liveness.begin(allowing: allowance)
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let watchdog = Task {
                while let wait = liveness.timeLeft() {
                    try? await Task.sleep(for: wait)
                    if Task.isCancelled { return }
                }
                guard answer.claim() else { return }
                abandon()
                continuation.resume(throwing: RemoteFileServiceError.connectionFailed(
                    underlying: String(localized: "連線逾時", bundle: .module)))
            }
            worker.start {
                do {
                    let value = try await work()
                    liveness.touch()
                    if answer.claim() { continuation.resume(returning: value) }
                } catch {
                    // An error the server sent back is an answer all the same.
                    if error is ErrorResponse { liveness.touch() }
                    if answer.claim() { continuation.resume(throwing: error) }
                }
                liveness.end(allowing: allowance)
                watchdog.cancel()
            }
        }
    } onCancel: {
        worker.cancel()
    }
}

/// When a session last showed that its connection carries anything, and how
/// long it may go without.
///
/// SMBClient sends one request at a time on a connection, so a call can wait
/// behind another's transfer for as long as that takes, however well the
/// link is doing. Timed on its own, the waiting call would write a working
/// session off for being busy. Requests are serialized, so any answer on the
/// session shows the link moving for every call waiting on it. Time with no
/// call in flight is not silence: the count starts afresh when the session
/// next has something to wait for.
final class Liveness: @unchecked Sendable {
    private let lock = NSLock()
    private var lastSign = ContinuousClock.now
    /// One for each call in flight. The longest decides, because the calls
    /// queued behind a listing wait on the same link it does.
    private var allowances: [Duration] = []

    func begin(allowing allowance: Duration, at now: ContinuousClock.Instant = .now) {
        lock.withLock {
            if allowances.isEmpty { lastSign = now }
            allowances.append(allowance)
        }
    }

    func end(allowing allowance: Duration) {
        lock.withLock {
            if let index = allowances.firstIndex(of: allowance) { allowances.remove(at: index) }
        }
    }

    func touch(at now: ContinuousClock.Instant = .now) {
        lock.withLock { lastSign = max(lastSign, now) }
    }

    /// How long until the session has been silent for longer than the calls
    /// in flight allow, if it has not been yet.
    func timeLeft(at now: ContinuousClock.Instant = .now) -> Duration? {
        lock.withLock {
            guard let allowance = allowances.max() else { return nil }
            let left = lastSign + allowance - now
            return left > .zero ? left : nil
        }
    }
}

/// Whether a call's caller has been answered: the work and the watchdog race
/// to do it, and only the first may.
private final class Answer: @unchecked Sendable {
    private let lock = NSLock()
    private var isGiven = false

    func claim() -> Bool {
        lock.withLock {
            defer { isGiven = true }
            return !isGiven
        }
    }
}

/// The task running a piece of work, so that cancelling the caller reaches
/// it — even when the cancellation arrives before the task exists.
private final class Worker: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var isCancelled = false

    func start(_ body: @escaping @Sendable () async -> Void) {
        let task = Task { await body() }
        let cancelled = lock.withLock {
            self.task = task
            return isCancelled
        }
        if cancelled { task.cancel() }
    }

    func cancel() {
        let task = lock.withLock {
            isCancelled = true
            return self.task
        }
        task?.cancel()
    }
}

extension SMBClient: @unchecked @retroactive Sendable {}

/// The requests `replace` makes, which SMBClient answers as it is; there is
/// no SMB server to test against in process, so tests answer them from a
/// share kept in memory.
protocol SMBReplacing {
    func move(from: String, to: String) async throws
    func existDirectory(path: String) async throws -> Bool
    func deleteFile(path: String) async throws
}

extension SMBClient: SMBReplacing {}
