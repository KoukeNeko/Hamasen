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
import NIOCore
import NIOPosix
import NIOSSL

/// FTP implementation of RemoteFileService.
///
/// An actor, but that alone does not make operations run one at a time: an
/// actor is reentrant at every `await`, and a session is one control
/// connection on which FTP cannot tell replies apart if two commands are in
/// flight. Each public operation therefore holds the operation lock for its
/// whole command sequence — data transfer and closing reply included.
public actor FTPFileService: RemoteFileService {
    private static let log = HamasenLog(category: "ftp")

    private let config: ServerConfig
    private let credentials: ServerCredentials
    private let connectTimeoutSeconds: Int

    private var control: FTPControlConnection?
    /// What the server said it can do, from FEAT. Absent until login.
    private var features: Set<String> = []
    /// Set once PROT P has been agreed, and used for every data connection
    /// after that.
    private var dataProtection: FTPDataProtection = .clear

    /// The operation lock. Ownership is handed straight to the next waiter on
    /// release, which keeps the order first come, first served.
    private var operationInFlight = false
    private var operationQueue: [CheckedContinuation<Void, Never>] = []

    public init(
        config: ServerConfig,
        credentials: ServerCredentials,
        connectTimeoutSeconds: Int = AppSettings.defaultConnectTimeoutSeconds
    ) {
        self.config = config
        self.credentials = credentials
        self.connectTimeoutSeconds = connectTimeoutSeconds
    }

    // MARK: - Serialization

    private func acquireOperationLock() async {
        if !operationInFlight {
            operationInFlight = true
            return
        }
        await withCheckedContinuation { operationQueue.append($0) }
    }

    private func releaseOperationLock() {
        if operationQueue.isEmpty {
            operationInFlight = false
        } else {
            operationQueue.removeFirst().resume()
        }
    }

    /// Runs one operation's whole command sequence alone on the connection,
    /// and turns whatever goes wrong into the error callers expect.
    private func perform<Result>(
        operation: String,
        path: String,
        _ body: (FTPControlConnection) async throws -> Result
    ) async throws -> Result {
        await acquireOperationLock()
        defer { releaseOperationLock() }
        // Waiting behind another transfer can take long enough for the
        // caller to give up; a delete or rename it abandoned must not run
        // once its turn comes.
        try Task.checkCancellation()

        let connection = try requireConnection()
        do {
            return try await body(connection)
        } catch {
            throw await serviceError(for: error, on: connection, operation: operation, path: path)
        }
    }

    // MARK: - Connection lifecycle

    public func connect() async throws {
        await acquireOperationLock()
        defer { releaseOperationLock() }

        guard control == nil else { return }
        guard case .password(let password) = credentials else {
            throw RemoteFileServiceError.unsupportedCredentials(
                protocolName: config.transferProtocol.displayName
            )
        }

        let tlsMode: FTPTLSMode = config.transferProtocol == .ftps ? .explicit : .none
        let (connection, _) = try await FTPControlConnection.connect(
            host: config.host,
            port: config.port,
            timeoutSeconds: connectTimeoutSeconds,
            tls: tlsMode
        )

        do {
            let user = try await connection.send("USER \(config.username)")
            // 331 asks for the password; 230 means the server wanted none.
            if user.isPositiveIntermediate {
                let pass = try await connection.send("PASS \(password)", redactingArgument: true)
                guard pass.isPositiveCompletion else {
                    throw FTPError.commandFailed(command: "PASS", response: pass)
                }
            } else if !user.isPositiveCompletion {
                throw FTPError.commandFailed(command: "USER", response: user)
            }

            features = await Self.readFeatures(from: connection)
            // Names travel as UTF-8 only if asked for; without this a server
            // defaults to Latin-1 and non-ASCII names come back mangled.
            if features.contains("UTF8") {
                await Self.enableUTF8(on: connection)
            }
            // Binary, always: the alternative rewrites line endings inside
            // files in transit.
            try await connection.expect("TYPE I")

            if tlsMode == .explicit {
                // Protecting the commands and leaving the files in the clear
                // is the mistake this pair exists to prevent. PBSZ is
                // required first and is always 0 over TLS.
                try await connection.expect("PBSZ 0")
                try await connection.expect("PROT P")
                dataProtection = .tls(context: try FTPTLS.makeContext(), hostname: config.host)
            }
        } catch {
            await connection.close()
            features = []
            throw Self.serviceError(error, operation: Self.connectOperation, path: config.host)
        }

        control = connection
    }

    public func disconnect() async throws {
        let connection = control
        control = nil
        features = []
        dataProtection = .clear
        guard let connection else { return }
        // With an operation still running, QUIT would be answered in the
        // middle of its replies; closing is what stops that operation.
        if !operationInFlight {
            _ = try? await connection.send("QUIT")
        }
        await connection.close()
    }

    public var isConnected: Bool {
        get async {
            guard let control else { return false }
            return await control.isActive
        }
    }

    /// Forgets a session that cannot be trusted any more, so `isConnected`
    /// turns false and the next use gets a fresh one.
    ///
    /// Anything that leaves a reply unread, or a transfer half done, ends up
    /// here: the reply arrives later and is taken for the answer to the next
    /// command, and every command after it is then off by one.
    private func dropSession(_ connection: FTPControlConnection) async {
        if control === connection {
            control = nil
            features = []
            dataProtection = .clear
        }
        await connection.close()
    }

    /// The commands FEAT reports, upper-cased and reduced to their names, so
    /// "MLST type*;size*;" counts as MLST.
    private static func readFeatures(from connection: FTPControlConnection) async -> Set<String> {
        // Optional: a server without FEAT is still a working server.
        let response: FTPResponse
        do {
            response = try await connection.send("FEAT")
        } catch {
            log.notice("FEAT failed, continuing without optional features: \(String(describing: error))")
            return []
        }
        guard response.isPositiveCompletion else {
            log.notice("FEAT refused with \(response.code), continuing without optional features")
            return []
        }
        // The first and last lines are the reply's own text, not features.
        return Set(
            response.lines.dropFirst().dropLast().compactMap { line in
                line.trimmingCharacters(in: .whitespaces)
                    .split(separator: " ").first
                    .map { $0.uppercased() }
            }
        )
    }

    private static func enableUTF8(on connection: FTPControlConnection) async {
        do {
            let response = try await connection.send("OPTS UTF8 ON")
            if !response.isPositiveCompletion {
                log.notice("OPTS UTF8 ON refused with \(response.code), names may be mangled")
            }
        } catch {
            log.notice("OPTS UTF8 ON failed, names may be mangled: \(String(describing: error))")
        }
    }

    // MARK: - Listing

    public func listDirectory(at path: String) async throws -> [RemoteItem] {
        try await perform(operation: Self.listOperation, path: path) { connection in
            // Uploads in flight are not part of the folder yet.
            let entries = try await rawEntries(in: path, on: connection)
                .filter { !RemotePath.isTemporaryUpload(name: $0.name) }
            return try await resolvingLinks(in: entries, on: connection)
        }
    }

    /// RFC 3659 has a server that supports MLST support MLSD too, and lists
    /// only MLST in FEAT; a server that names MLSD is taken at its word.
    private var supportsMachineListing: Bool {
        features.contains("MLST") || features.contains("MLSD")
    }

    /// A directory's entries exactly as the server lists them, links still
    /// links. Deleting has to see them that way, and the item lookup compares
    /// against them.
    private func rawEntries(in path: String, on connection: FTPControlConnection) async throws -> [RemoteItem] {
        try await rawEntries(inServerDirectory: resolve(path), reportedAs: path, on: connection)
    }

    /// A listing of a directory named by its path on the server rather than
    /// in the mount, with entries reported under `directory`.
    private func rawEntries(
        inServerDirectory remotePath: String, reportedAs directory: String, on connection: FTPControlConnection
    ) async throws -> [RemoteItem] {
        // MLSD states what each entry is; LIST leaves it to be guessed from
        // whatever the server's directory tool prints.
        if supportsMachineListing {
            let body = try await transferIn(command: "MLSD \(remotePath)", on: connection)
            return FTPListing.parseMachineListing(body, directory: directory)
        }
        let body = try await transferIn(command: "LIST \(remotePath)", on: connection)
        return FTPListing.parseUnixListing(body, directory: directory)
    }

    /// Reports each symlink as whatever it points at.
    ///
    /// A listing says an entry is a link; asking about that one path answers
    /// with what CWD accepts, which for a link to a folder is a folder. The
    /// system compares the two and retries that reconciliation for as long
    /// as the item exists. Listing and lookup both come through
    /// `resolveLink`, which is what keeps the two answers the same.
    private func resolvingLinks(
        in entries: [RemoteItem],
        on connection: FTPControlConnection
    ) async throws -> [RemoteItem] {
        guard entries.contains(where: { $0.kind == .symlink }) else { return entries }
        var resolved: [RemoteItem] = []
        for entry in entries {
            resolved.append(entry.kind == .symlink ? try await resolveLink(entry, on: connection) : entry)
        }
        return resolved
    }

    private func resolveLink(_ link: RemoteItem, on connection: FTPControlConnection) async throws -> RemoteItem {
        let remotePath = resolve(link.path)
        do {
            // A directory is what CWD accepts; there is no other question a
            // server reliably answers about an item's type.
            if try await isDirectory(remotePath, on: connection) {
                return RemoteItem(
                    path: link.path,
                    name: link.name,
                    kind: .directory,
                    size: 0,
                    modificationDate: try? await modificationDate(of: remotePath, on: connection),
                    isResolvedLink: true
                )
            }
            let size = try await self.size(of: remotePath, on: connection)
            return RemoteItem(
                path: link.path,
                name: link.name,
                kind: .file,
                size: size,
                modificationDate: try? await modificationDate(of: remotePath, on: connection),
                isResolvedLink: true
            )
        } catch let error as FTPError where !error.isConnectionLevel {
            // A link that points nowhere stays a link, which is what it is.
            return link
        }
    }

    public func itemInfo(at path: String) async throws -> RemoteItem {
        try await perform(operation: Self.infoOperation, path: path) { connection in
            let item = try await lookup(path, on: connection)
            return item.kind == .symlink ? try await resolveLink(item, on: connection) : item
        }
    }

    /// One item as the parent's listing reports it.
    ///
    /// The version the system keeps is size plus modification time, and
    /// servers report time to different precisions from different commands:
    /// asking SIZE and MDTM here would give a file a second version that the
    /// listing never agrees with, and it would be fetched again for good.
    /// MLST answers in the facts MLSD uses; otherwise the listing itself is
    /// the only source that matches.
    private func lookup(_ path: String, on connection: FTPControlConnection) async throws -> RemoteItem {
        guard path != RemotePath.root else {
            return RemoteItem(path: path, name: "/", kind: .directory, size: 0)
        }

        if features.contains("MLST") {
            let response = try await connection.send("MLST \(resolve(path))")
            if response.isPositiveCompletion,
               let item = FTPListing.parseMachineStatus(response, path: path) {
                return item
            }
            let failure = FTPError.commandFailed(command: "MLST", response: response)
            if response.isFailure, response.code == 550 || failure.isConnectionLevel { throw failure }
        }

        let name = RemotePath.name(of: path)
        let entries = try await rawEntries(in: RemotePath.parent(of: path), on: connection)
        guard let entry = entries.first(where: { $0.name == name }) else {
            throw RemoteFileServiceError.itemNotFound(path: path)
        }
        return entry
    }

    /// Whether a path is a directory.
    ///
    /// CWD is the question every server answers, and answering it moves the
    /// session's working directory as a side effect. That is harmless here
    /// only because every command this client sends carries an absolute
    /// path — a relative one would start resolving against wherever the last
    /// call to this left things.
    private func isDirectory(_ remotePath: String, on connection: FTPControlConnection) async throws -> Bool {
        let response = try await connection.send("CWD \(remotePath)")
        return response.isPositiveCompletion
    }

    private func size(of remotePath: String, on connection: FTPControlConnection) async throws -> Int64 {
        let response = try await connection.expect("SIZE \(remotePath)")
        return Int64(response.text.trimmingCharacters(in: .whitespaces)) ?? 0
    }

    private func modificationDate(
        of remotePath: String,
        on connection: FTPControlConnection
    ) async throws -> Date? {
        guard features.contains("MDTM") else { return nil }
        let response = try await connection.expect("MDTM \(remotePath)")
        return FTPTimestamp.parse(response.text.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Reading

    public func downloadFile(at path: String, to localURL: URL, progress: TransferProgress?) async throws {
        try await perform(operation: Self.downloadOperation, path: path) { connection in
            FileManager.default.createFile(atPath: localURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: localURL)
            defer { try? handle.close() }

            let written = ByteCounter()
            try await runTransfer("RETR \(resolve(path))", on: connection) { channel in
                try await FTPDataConnection.receive(
                    on: channel,
                    timeoutSeconds: connectTimeoutSeconds,
                    protection: dataProtection
                ) { buffer in
                    try handle.write(contentsOf: Data(buffer.readableBytesView))
                    progress?(written.add(buffer.readableBytes))
                }
            }
        }
    }

    public func downloadRange(at path: String, offset: Int64, length: Int) async throws -> Data {
        try await perform(operation: Self.downloadOperation, path: path) { connection in
            // REST says where to start and there is no way to say where to
            // stop, so the connection is closed once enough has arrived.
            // Reading to the end instead would pull the whole remainder of
            // the file into memory — which is the thing a ranged read exists
            // to avoid.
            return try await runTransfer(
                "RETR \(resolve(path))",
                restartingAt: offset,
                on: connection,
                allowingAbort: true,
                tolerateSilentServer: true
            ) { channel in
                try await FTPDataConnection.receiveAll(
                    on: channel,
                    timeoutSeconds: connectTimeoutSeconds,
                    protection: dataProtection,
                    stoppingAfter: length
                )
            }
        }
    }

    // MARK: - Writing

    /// Uploads under a temporary name and renames it into place. STOR writes
    /// in place and truncates first, so a connection lost halfway would leave
    /// half a file under the real name.
    public func uploadFile(from localURL: URL, to path: String, progress: TransferProgress?) async throws {
        guard FileManager.default.isReadableFile(atPath: localURL.path) else {
            throw RemoteFileServiceError.localFileUnreadable(url: localURL)
        }
        try await perform(operation: Self.uploadOperation, path: path) { connection in
            let temporaryPath = RemotePath.temporaryUploadPath(for: path)
            do {
                try await store(localURL, at: resolve(temporaryPath), progress: progress, on: connection)
                try await promoteUpload(from: resolve(temporaryPath), to: resolve(path), on: connection)
            } catch let incomplete as PromotionIncomplete {
                // The old file is gone and the upload is the only copy left
                // on the server, so it stays under its temporary name, where
                // listings hide it but nothing removes it.
                Self.log.error(
                    "Upload of \(path) could not be renamed into place and the old file could not be put back; "
                    + "the new content is at \(temporaryPath), the old at \(incomplete.oldFileAt): "
                    + "\(String(describing: incomplete.underlying))")
                throw incomplete.underlying
            } catch {
                await discardTemporaryUpload(at: resolve(temporaryPath), on: connection)
                if let ftpError = error as? FTPError,
                   case .commandFailed(let command, let response) = ftpError,
                   ["RNFR", "RNTO", "DELE"].contains(command), !ftpError.isConnectionLevel {
                    // The temporary name is ours, so a refusal about it says
                    // nothing about the file the caller named.
                    throw RemoteFileServiceError.operationFailed(
                        operation: Self.uploadOperation, path: path, underlying: response.text
                    )
                }
                throw error
            }
        }
    }

    private func store(
        _ localURL: URL,
        at remotePath: String,
        progress: TransferProgress?,
        on connection: FTPControlConnection
    ) async throws {
        try await runTransfer("STOR \(remotePath)", on: connection) { channel in
            try await FTPDataConnection.send(
                contentsOf: localURL,
                on: channel,
                timeoutSeconds: connectTimeoutSeconds,
                protection: dataProtection,
                progress: progress
            )
        }
    }

    /// Thrown once the destination has been moved aside and the upload could
    /// neither take its place nor the old file be put back.
    private struct PromotionIncomplete: Error {
        let underlying: Error
        let oldFileAt: String
    }

    /// Renames the upload over the destination.
    ///
    /// Some servers refuse to rename onto a file that exists, and deleting
    /// it first would leave a window in which a failure loses both versions.
    /// So the old file is moved aside instead, and only deleted once the
    /// upload is in place; if the upload cannot be renamed, the old file is
    /// put back.
    private func promoteUpload(
        from temporaryPath: String,
        to remotePath: String,
        on connection: FTPControlConnection
    ) async throws {
        let refusal: FTPResponse
        do {
            try await rename(from: temporaryPath, to: remotePath, on: connection)
            return
        } catch let error as FTPError {
            guard case .commandFailed("RNTO", let response) = error, response.isPermanentFailure else { throw error }
            refusal = response
        }

        let backup = RemotePath.temporaryUploadPath(for: remotePath)
        do {
            try await rename(from: remotePath, to: backup, on: connection)
        } catch let error as FTPError where !error.isConnectionLevel {
            // Nothing to move aside, or not allowed to: the refusal that
            // started this is the one the caller should hear about.
            throw FTPError.commandFailed(command: "RNTO", response: refusal)
        }
        // Checked on what was moved, so nothing can change it in between. A
        // directory put there by someone else during the upload is not a
        // file to replace — and DELE could not remove it afterwards — so it
        // goes back and the upload fails.
        let backupDirectory = RemotePath.parent(of: backup)
        let movedKind = try? await rawEntries(
            inServerDirectory: backupDirectory, reportedAs: backupDirectory, on: connection
        ).first { $0.name == RemotePath.name(of: backup) }?.kind
        guard movedKind == .file else {
            do {
                try await rename(from: backup, to: remotePath, on: connection)
            } catch {
                throw PromotionIncomplete(underlying: error, oldFileAt: backup)
            }
            throw RemoteFileServiceError.alreadyExists(path: remotePath)
        }
        do {
            try await rename(from: temporaryPath, to: remotePath, on: connection)
        } catch {
            do {
                try await rename(from: backup, to: remotePath, on: connection)
            } catch {
                throw PromotionIncomplete(underlying: error, oldFileAt: backup)
            }
            throw error
        }
        await discardTemporaryUpload(at: backup, on: connection)
    }

    /// Best effort: the upload has already failed, and this only tidies up
    /// after it. A session that has been dropped cannot be asked.
    private func discardTemporaryUpload(at remotePath: String, on connection: FTPControlConnection) async {
        guard control === connection, await connection.isActive else { return }
        do {
            try await connection.expect("DELE \(remotePath)")
        } catch {
            Self.log.notice("could not remove temporary upload \(remotePath): \(String(describing: error))")
        }
    }

    public func createDirectory(at path: String) async throws {
        try await perform(operation: Self.createDirectoryOperation, path: path) { connection in
            do {
                try await connection.expect("MKD \(resolve(path))")
            } catch FTPError.commandFailed(_, let response) where [550, 521].contains(response.code) {
                if await pathExists(path, on: connection) == true {
                    throw RemoteFileServiceError.alreadyExists(path: path)
                }
                throw FTPError.commandFailed(command: "MKD", response: response)
            }
        }
    }

    public func deleteFile(at path: String) async throws {
        _ = try await perform(operation: Self.deleteOperation, path: path) { connection in
            try await connection.expect("DELE \(resolve(path))")
        }
    }

    /// Recursive by contract, and by hand: FTP has no command that removes a
    /// directory with anything in it.
    ///
    /// Never through a link. Listings and lookups report a link as what it
    /// points at, so a link to a folder looks like a folder — and walking it
    /// deletes the target's files. This works from the raw entries, where a
    /// link is still a link, and removes it as the file it is.
    public func listDirectoryWithoutFollowingLinks(at path: String) async throws -> [RemoteItem] {
        try await perform(operation: Self.listOperation, path: path) { connection in
            try await rawEntries(in: path, on: connection)
                .filter { !RemotePath.isTemporaryUpload(name: $0.name) }
        }
    }

    public func deleteDirectory(at path: String) async throws {
        try await perform(operation: Self.deleteOperation, path: path) { connection in
            if try await lookup(path, on: connection).kind == .symlink {
                try await connection.expect("DELE \(resolve(path))")
                return
            }
            try await deleteTree(at: path, on: connection)
        }
    }

    private func deleteTree(at path: String, on connection: FTPControlConnection) async throws {
        for child in try await rawEntries(in: path, on: connection) {
            do {
                if child.kind == .directory {
                    try await deleteTree(at: child.path, on: connection)
                } else {
                    try await connection.expect("DELE \(resolve(child.path))")
                }
            } catch {
                // Said about the child that failed, not the folder asked for.
                throw await serviceError(
                    for: error, on: connection, operation: Self.deleteOperation, path: child.path
                )
            }
        }
        try await connection.expect("RMD \(resolve(path))")
    }

    public func moveItem(from oldPath: String, to newPath: String) async throws {
        try await perform(operation: Self.moveOperation, path: oldPath) { connection in
            do {
                try await rename(from: resolve(oldPath), to: resolve(newPath), on: connection)
            } catch FTPError.commandFailed("RNTO", let response) where [550, 553].contains(response.code) {
                if await pathExists(newPath, on: connection) == true {
                    throw RemoteFileServiceError.alreadyExists(path: newPath)
                }
                throw FTPError.commandFailed(command: "RNTO", response: response)
            }
        }
    }

    /// RNFR names the source and answers 350; the rename only happens when
    /// RNTO follows it.
    private func rename(from source: String, to destination: String, on connection: FTPControlConnection) async throws {
        try await connection.expect("RNFR \(source)")
        try await connection.expect("RNTO \(destination)")
    }

    // MARK: - Transfers

    /// Asks the server where to open the data connection, preferring EPSV.
    ///
    /// EPSV names only a port, so the data connection goes where the commands
    /// already go — which is the answer that survives NAT, where the address
    /// PASV reports is the one the server believes it has.
    private func enterPassiveMode(on connection: FTPControlConnection) async throws -> FTPPassiveAddress {
        if features.contains("EPSV") || features.isEmpty {
            let response = try await connection.send("EPSV")
            if response.isPositiveCompletion,
               let address = FTPPassiveAddress.extendedPassive(from: response) {
                return address
            }
        }
        let response = try await connection.expect("PASV")
        guard let address = FTPPassiveAddress.passive(from: response) else {
            throw FTPError.unreadableAddress(response: response)
        }
        return address
    }

    /// Sends the command that starts a transfer and checks the server took it.
    private func startTransfer(_ command: String, on connection: FTPControlConnection) async throws {
        let started = try await connection.send(command)
        guard started.isPositivePreliminary || started.isPositiveCompletion else {
            throw FTPError.commandFailed(command: FTPError.name(of: command), response: started)
        }
    }

    /// Runs a command whose answer arrives on a data connection.
    private func transferIn(command: String, on connection: FTPControlConnection) async throws -> String {
        let body = try await runTransfer(command, on: connection) { channel in
            try await FTPDataConnection.receiveAll(
                on: channel,
                timeoutSeconds: connectTimeoutSeconds,
                protection: dataProtection
            )
        }
        return String(decoding: body, as: UTF8.self)
    }

    /// One transfer, in the order that works with every server: passive
    /// mode, the data connection opened, then the command, then its 1xx
    /// reply, the data, and the closing reply. Servers such as vsftpd send
    /// the 1xx reply only once the data connection has been accepted.
    private func runTransfer<Result>(
        _ command: String,
        restartingAt offset: Int64? = nil,
        on connection: FTPControlConnection,
        allowingAbort: Bool = false,
        tolerateSilentServer: Bool = false,
        moving move: (Channel) async throws -> Result
    ) async throws -> Result {
        let address = try await enterPassiveMode(on: connection)
        let channel = try await FTPDataConnection.connect(
            to: address,
            fallbackHost: await connection.remoteHost ?? config.host,
            group: MultiThreadedEventLoopGroup.singleton,
            timeoutSeconds: connectTimeoutSeconds
        )
        defer { channel.close(promise: nil) }

        if let offset, offset > 0 {
            // REST sets where the next transfer starts; it is only
            // meaningful immediately before one.
            try await connection.expect("REST \(offset)")
        }
        try await startTransfer(command, on: connection)
        return try await completeTransfer(
            on: connection,
            command: FTPError.name(of: command),
            allowingAbort: allowingAbort,
            tolerateSilentServer: tolerateSilentServer
        ) { try await move(channel) }
    }

    /// Moves the data, then reads the reply that closes the transfer. A
    /// transfer is finished when the data connection has closed *and* the
    /// server has said so; taking the closed connection alone as the answer
    /// reports success on a transfer the server aborted halfway.
    ///
    /// A failure while moving the data, or in waiting for the reply, leaves
    /// that reply on its way to the next command, so the session is dropped
    /// rather than reused. A reply that arrives and says the transfer failed
    /// leaves the session in step, and is reported as an ordinary failure.
    /// - Parameter allowingAbort: accepts the reply a server sends when the
    ///   data connection closed before it had finished writing, which is what
    ///   a deliberately truncated read looks like from its side.
    /// - Parameter tolerateSilentServer: for a read that closed the data
    ///   connection itself, where some servers never say anything. The bytes
    ///   are already in hand, so they are returned and only the session is
    ///   given up.
    private func completeTransfer<Result>(
        on connection: FTPControlConnection,
        command: String,
        allowingAbort: Bool = false,
        tolerateSilentServer: Bool = false,
        moving move: () async throws -> Result
    ) async throws -> Result {
        let result: Result
        do {
            result = try await move()
        } catch {
            await dropSession(connection)
            throw error
        }

        let completion: FTPResponse
        do {
            completion = try await connection.awaitCompletion()
        } catch FTPError.timedOut where tolerateSilentServer {
            Self.log.notice("no closing reply for \(command), dropping the session")
            await dropSession(connection)
            return result
        } catch {
            await dropSession(connection)
            throw error
        }

        if completion.isPositiveCompletion { return result }
        if allowingAbort, Self.abortedTransferCodes.contains(completion.code) { return result }
        throw FTPError.commandFailed(command: command, response: completion)
    }

    /// 426 is "connection closed, transfer aborted"; 226 arrives instead on
    /// servers that treat the close as an ordinary end.
    private static let abortedTransferCodes: Set<Int> = [426, 225]

    // MARK: - Errors

    /// The error a caller sees, and the point where a session that has gone
    /// bad is dropped.
    private func serviceError(
        for error: Error,
        on connection: FTPControlConnection,
        operation: String,
        path: String
    ) async -> Error {
        if error is CancellationError || error is RemoteFileServiceError { return error }

        if let ftpError = error as? FTPError {
            if ftpError.isConnectionLevel {
                await dropSession(connection)
            } else if case .commandFailed(let command, let response) = ftpError,
                      let refusal = await classifyRefusal(
                          command: command, response: response,
                          operation: operation, path: path, on: connection
                      ) {
                return refusal
            }
        } else if Self.isTransportError(error) {
            await dropSession(connection)
            return RemoteFileServiceError.connectionFailed(underlying: String(describing: error))
        }
        return Self.serviceError(error, operation: operation, path: path)
    }

    /// Commands whose 550 means "not there, or not yours" and nothing more.
    private static let missingOrRefusedCommands: Set<String> = [
        "SIZE", "MDTM", "CWD", "RETR", "DELE", "RMD", "RNFR", "MLST", "MLSD", "LIST",
    ]

    /// Servers word these refusals differently and in their own languages,
    /// so the text cannot say which it was. The parent's listing can: a name
    /// that is not in it is missing, and one that is in it was refused.
    private func classifyRefusal(
        command: String,
        response: FTPResponse,
        operation: String,
        path: String,
        on connection: FTPControlConnection
    ) async -> RemoteFileServiceError? {
        if command == "STOR", [550, 553, 532].contains(response.code) {
            return .permissionDenied(operation: operation, path: path)
        }
        guard response.code == 550, Self.missingOrRefusedCommands.contains(command) else { return nil }
        if response.text.lowercased().contains("no such") { return .itemNotFound(path: path) }
        switch await pathExists(path, on: connection) {
        case false: return .itemNotFound(path: path)
        case true: return .permissionDenied(operation: operation, path: path)
        default: return nil
        }
    }

    /// Whether the parent's listing names this path. nil when that cannot be
    /// told: a parent that will not list is either gone, which its own
    /// parent settles, or unreadable, which settles nothing.
    private func pathExists(_ path: String, on connection: FTPControlConnection) async -> Bool? {
        guard path != RemotePath.root else { return true }
        guard control === connection else { return nil }
        let parent = RemotePath.parent(of: path)
        do {
            let name = RemotePath.name(of: path)
            return try await rawEntries(in: parent, on: connection).contains { $0.name == name }
        } catch FTPError.commandFailed(_, let response) where response.code == 550 {
            return await pathExists(parent, on: connection) == false ? false : nil
        } catch {
            return nil
        }
    }

    private static func isTransportError(_ error: Error) -> Bool {
        error is ChannelError || error is IOError || error is NIOConnectionError
            || error is NIOSSLError || error is BoringSSLError
    }

    // MARK: - Helpers

    private func requireConnection() throws -> FTPControlConnection {
        guard let control else { throw RemoteFileServiceError.notConnected }
        return control
    }

    /// Mount-relative paths become server paths (remotePath + relative path).
    private func resolve(_ mountRelativePath: String) -> String {
        RemotePath.resolve(mountRelativePath, against: config.remotePath)
    }

    private static func serviceError(_ error: Error, operation: String, path: String) -> Error {
        if let ftpError = error as? FTPError {
            return ftpError.asServiceError(operation: operation, path: path)
        }
        if error is RemoteFileServiceError || error is CancellationError { return error }
        if isTransportError(error) {
            return RemoteFileServiceError.connectionFailed(underlying: String(describing: error))
        }
        Self.log.error("\(operation) at \(path) failed: \(String(describing: error))")
        return RemoteFileServiceError.operationFailed(
            operation: operation,
            path: path,
            underlying: String(describing: error)
        )
    }

    private static var connectOperation: String { String(localized: "連線", bundle: .module) }
    private static var listOperation: String { String(localized: "列出目錄", bundle: .module) }
    private static var infoOperation: String { String(localized: "讀取屬性", bundle: .module) }
    private static var downloadOperation: String { String(localized: "下載", bundle: .module) }
    private static var uploadOperation: String { String(localized: "上傳", bundle: .module) }
    private static var createDirectoryOperation: String { String(localized: "建立目錄", bundle: .module) }
    private static var deleteOperation: String { String(localized: "刪除檔案", bundle: .module) }
    private static var moveOperation: String { String(localized: "移動項目", bundle: .module) }
}

/// A running total, written on the data connection's event loop only.
private final class ByteCounter: @unchecked Sendable {
    private var total: Int64 = 0

    func add(_ count: Int) -> Int64 {
        total += Int64(count)
        return total
    }
}

/// The timestamps FTP replies carry, which RFC 3659 fixes as UTC.
enum FTPTimestamp {
    static func parse(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = value.count > 14 ? "yyyyMMddHHmmss.SSS" : "yyyyMMddHHmmss"
        return formatter.date(from: value)
    }
}
