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
/// An actor because a session is one control connection and FTP has no way to
/// tell replies apart if two commands are in flight: everything here is one
/// at a time, by the protocol's own design.
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

    public init(
        config: ServerConfig,
        credentials: ServerCredentials,
        connectTimeoutSeconds: Int = AppSettings.defaultConnectTimeoutSeconds
    ) {
        self.config = config
        self.credentials = credentials
        self.connectTimeoutSeconds = connectTimeoutSeconds
    }

    // MARK: - Connection lifecycle

    public func connect() async throws {
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
                _ = try? await connection.send("OPTS UTF8 ON")
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
        _ = try? await connection.send("QUIT")
        await connection.close()
    }

    public var isConnected: Bool {
        get async {
            guard let control else { return false }
            return await control.isActive
        }
    }

    /// The commands FEAT reports, upper-cased and reduced to their names, so
    /// "MLST type*;size*;" counts as MLST.
    private static func readFeatures(from connection: FTPControlConnection) async -> Set<String> {
        guard let response = try? await connection.send("FEAT"), response.isPositiveCompletion else {
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

    // MARK: - Listing

    public func listDirectory(at path: String) async throws -> [RemoteItem] {
        let connection = try requireConnection()
        let remotePath = resolve(path)
        do {
            // MLSD states what each entry is; LIST leaves it to be guessed
            // from whatever the server's directory tool prints.
            if features.contains("MLSD") {
                let body = try await transferIn(command: "MLSD \(remotePath)", on: connection)
                return FTPListing.parseMachineListing(body, directory: path)
            }
            let body = try await transferIn(command: "LIST \(remotePath)", on: connection)
            return FTPListing.parseUnixListing(body, directory: path)
        } catch {
            throw Self.serviceError(error, operation: Self.listOperation, path: path)
        }
    }

    public func itemInfo(at path: String) async throws -> RemoteItem {
        let connection = try requireConnection()
        guard path != RemotePath.root else {
            return RemoteItem(path: path, name: "/", kind: .directory, size: 0)
        }
        let remotePath = resolve(path)

        do {
            // A directory is what CWD accepts; there is no other question a
            // server reliably answers about an item's type.
            if try await isDirectory(remotePath, on: connection) {
                return RemoteItem(
                    path: path,
                    name: RemotePath.name(of: path),
                    kind: .directory,
                    size: 0,
                    modificationDate: try? await modificationDate(of: remotePath, on: connection)
                )
            }
            let size = try await self.size(of: remotePath, on: connection)
            return RemoteItem(
                path: path,
                name: RemotePath.name(of: path),
                kind: .file,
                size: size,
                modificationDate: try? await modificationDate(of: remotePath, on: connection)
            )
        } catch {
            throw Self.serviceError(error, operation: Self.infoOperation, path: path)
        }
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

    public func downloadFile(at path: String, to localURL: URL) async throws {
        let connection = try requireConnection()
        do {
            FileManager.default.createFile(atPath: localURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: localURL)
            defer { try? handle.close() }

            let address = try await enterPassiveMode(on: connection)
            let started = try await connection.send("RETR \(resolve(path))")
            guard started.isPositivePreliminary || started.isPositiveCompletion else {
                throw FTPError.commandFailed(command: "RETR", response: started)
            }
            try await FTPDataConnection.receive(
                at: address,
                fallbackHost: await connection.remoteHost ?? config.host,
                group: MultiThreadedEventLoopGroup.singleton,
                timeoutSeconds: connectTimeoutSeconds,
                protection: dataProtection
            ) { buffer in
                try handle.write(contentsOf: Data(buffer.readableBytesView))
            }
            try await requireTransferCompleted(on: connection)
        } catch {
            throw Self.serviceError(error, operation: Self.downloadOperation, path: path)
        }
    }

    public func downloadRange(at path: String, offset: Int64, length: Int) async throws -> Data {
        let connection = try requireConnection()
        do {
            let address = try await enterPassiveMode(on: connection)
            if offset > 0 {
                // REST sets where the next transfer starts; it is only
                // meaningful immediately before one.
                try await connection.expect("REST \(offset)")
            }
            let started = try await connection.send("RETR \(resolve(path))")
            guard started.isPositivePreliminary || started.isPositiveCompletion else {
                throw FTPError.commandFailed(command: "RETR", response: started)
            }
            // REST says where to start and there is no way to say where to
            // stop, so the connection is closed once enough has arrived.
            // Reading to the end instead would pull the whole remainder of
            // the file into memory — which is the thing a ranged read exists
            // to avoid.
            let body = try await FTPDataConnection.receiveAll(
                at: address,
                fallbackHost: await connection.remoteHost ?? config.host,
                group: MultiThreadedEventLoopGroup.singleton,
                timeoutSeconds: connectTimeoutSeconds,
                protection: dataProtection,
                stoppingAfter: length
            )
            try await requireTransferCompleted(on: connection, allowingAbort: true)
            return body
        } catch {
            throw Self.serviceError(error, operation: Self.downloadOperation, path: path)
        }
    }

    // MARK: - Writing

    public func uploadFile(from localURL: URL, to path: String) async throws {
        let connection = try requireConnection()
        do {
            let address = try await enterPassiveMode(on: connection)
            let started = try await connection.send("STOR \(resolve(path))")
            guard started.isPositivePreliminary || started.isPositiveCompletion else {
                throw FTPError.commandFailed(command: "STOR", response: started)
            }
            try await FTPDataConnection.send(
                contentsOf: localURL,
                at: address,
                fallbackHost: await connection.remoteHost ?? config.host,
                group: MultiThreadedEventLoopGroup.singleton,
                timeoutSeconds: connectTimeoutSeconds,
                protection: dataProtection
            )
            try await requireTransferCompleted(on: connection)
        } catch {
            throw Self.serviceError(error, operation: Self.uploadOperation, path: path)
        }
    }

    public func createDirectory(at path: String) async throws {
        let connection = try requireConnection()
        do {
            try await connection.expect("MKD \(resolve(path))")
        } catch {
            throw Self.serviceError(error, operation: Self.createDirectoryOperation, path: path)
        }
    }

    public func deleteFile(at path: String) async throws {
        let connection = try requireConnection()
        do {
            try await connection.expect("DELE \(resolve(path))")
        } catch {
            throw Self.serviceError(error, operation: Self.deleteOperation, path: path)
        }
    }

    /// Recursive by contract, and by hand: FTP has no command that removes a
    /// directory with anything in it.
    public func deleteDirectory(at path: String) async throws {
        let connection = try requireConnection()
        for item in try await listDirectory(at: path) {
            if item.isDirectory {
                try await deleteDirectory(at: item.path)
            } else {
                try await deleteFile(at: item.path)
            }
        }
        do {
            try await connection.expect("RMD \(resolve(path))")
        } catch {
            throw Self.serviceError(error, operation: Self.deleteOperation, path: path)
        }
    }

    public func moveItem(from oldPath: String, to newPath: String) async throws {
        let connection = try requireConnection()
        do {
            // RNFR names the source and answers 350; the rename only happens
            // when RNTO follows it.
            try await connection.expect("RNFR \(resolve(oldPath))")
            try await connection.expect("RNTO \(resolve(newPath))")
        } catch {
            throw Self.serviceError(error, operation: Self.moveOperation, path: oldPath)
        }
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

    /// Runs a command whose answer arrives on a data connection.
    private func transferIn(command: String, on connection: FTPControlConnection) async throws -> String {
        let address = try await enterPassiveMode(on: connection)
        let started = try await connection.send(command)
        guard started.isPositivePreliminary || started.isPositiveCompletion else {
            throw FTPError.commandFailed(command: String(command.prefix(4)), response: started)
        }
        let body = try await FTPDataConnection.receiveAll(
            at: address,
            fallbackHost: await connection.remoteHost ?? config.host,
            group: MultiThreadedEventLoopGroup.singleton,
            timeoutSeconds: connectTimeoutSeconds,
            protection: dataProtection
        )
        try await requireTransferCompleted(on: connection)
        return String(decoding: body, as: UTF8.self)
    }

    /// A transfer is finished when the data connection has closed *and* the
    /// server has said so. Taking the closed connection alone as the answer
    /// reports success on a transfer the server aborted halfway.
    /// - Parameter allowingAbort: accepts the reply a server sends when the
    ///   data connection closed before it had finished writing, which is what
    ///   a deliberately truncated read looks like from its side.
    private func requireTransferCompleted(
        on connection: FTPControlConnection,
        allowingAbort: Bool = false
    ) async throws {
        let completion = try await connection.awaitCompletion()
        if completion.isPositiveCompletion { return }
        if allowingAbort, Self.abortedTransferCodes.contains(completion.code) { return }
        throw FTPError.commandFailed(command: "transfer", response: completion)
    }

    /// 426 is "connection closed, transfer aborted"; 226 arrives instead on
    /// servers that treat the close as an ordinary end.
    private static let abortedTransferCodes: Set<Int> = [426, 225]

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
        if error is RemoteFileServiceError { return error }
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
