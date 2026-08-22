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

    private static let log = HamasenLog(category: "sftp")

    private let config: ServerConfig
    private let credentials: ServerCredentials
    private let connectTimeoutSeconds: Int
    private let hostKeyPolicy: HostKeyPolicy
    private var sshClient: SSHClient?
    private var sftpClient: SFTPClient?

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
        guard sftpClient == nil else { return }

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
        } catch {
            Self.log.error("SSH connection to \(config.host):\(config.port) failed: \(String(describing: error))")
            throw RemoteFileServiceError.connectionFailed(underlying: String(describing: error))
        }

        do {
            sftpClient = try await client.openSFTP()
            sshClient = client
            Self.log.debug("SFTP session established with \(config.host)")
        } catch {
            Self.log.error("Opening SFTP subsystem on \(config.host) failed: \(String(describing: error))")
            try? await client.close()
            throw RemoteFileServiceError.connectionFailed(underlying: String(describing: error))
        }
    }

    /// The SSH channel's own view of itself: the server closing the session
    /// takes the channel down, which is visible here without a round trip.
    public var isConnected: Bool {
        sftpClient?.isActive ?? false
    }

    public func disconnect() async throws {
        let sftp = sftpClient
        let ssh = sshClient
        sftpClient = nil
        sshClient = nil
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
        let sftp = try activeSFTPClient()
        let remoteDirectory = remoteAbsolutePath(for: path)

        let nameBatches: [SFTPMessage.Name]
        do {
            nameBatches = try await sftp.listDirectory(atPath: remoteDirectory)
        } catch {
            throw Self.mapError(error, operation: String(localized: "列出目錄", bundle: .module), path: path)
        }

        return nameBatches
            .flatMap(\.components)
            .filter { $0.filename != "." && $0.filename != ".." }
            .map { component in
                Self.makeRemoteItem(
                    path: RemotePath.join(path, component.filename),
                    name: component.filename,
                    attributes: component.attributes
                )
            }
    }

    public func itemInfo(at path: String) async throws -> RemoteItem {
        let sftp = try activeSFTPClient()
        do {
            let attributes = try await sftp.getAttributes(at: remoteAbsolutePath(for: path))
            return Self.makeRemoteItem(path: path, name: RemotePath.name(of: path), attributes: attributes)
        } catch {
            throw Self.mapError(error, operation: String(localized: "讀取屬性", bundle: .module), path: path)
        }
    }

    public func downloadFile(at path: String, to localURL: URL) async throws {
        let sftp = try activeSFTPClient()

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
            try await sftp.withFile(
                filePath: remoteAbsolutePath(for: path),
                flags: .read
            ) { file in
                var offset: UInt64 = 0
                while true {
                    let chunk = try await file.read(from: offset, length: UInt32(Self.transferChunkSize))
                    let byteCount = chunk.readableBytes
                    guard byteCount > 0 else { break }
                    let bytes = chunk.getBytes(at: chunk.readerIndex, length: byteCount) ?? []
                    try localFile.write(contentsOf: Data(bytes))
                    offset += UInt64(byteCount)
                }
            }
        } catch {
            throw Self.mapError(error, operation: String(localized: "下載", bundle: .module), path: path)
        }
    }

    public func downloadRange(at path: String, offset: Int64, length: Int) async throws -> Data {
        let sftp = try activeSFTPClient()
        guard length > 0 else { return Data() }

        do {
            return try await sftp.withFile(
                filePath: remoteAbsolutePath(for: path),
                flags: .read
            ) { file in
                var collected = Data()
                collected.reserveCapacity(length)

                // A single SFTP read returns at most what the server allows,
                // so keep asking until the range is filled or the file ends.
                while collected.count < length {
                    let remaining = length - collected.count
                    let chunk = try await file.read(
                        from: UInt64(offset) + UInt64(collected.count),
                        length: UInt32(min(remaining, Self.transferChunkSize))
                    )
                    let byteCount = chunk.readableBytes
                    guard byteCount > 0 else { break }
                    collected.append(contentsOf: chunk.getBytes(at: chunk.readerIndex, length: byteCount) ?? [])
                }
                return collected
            }
        } catch {
            throw Self.mapError(error, operation: String(localized: "下載區間", bundle: .module), path: path)
        }
    }

    public func uploadFile(from localURL: URL, to path: String) async throws {
        let sftp = try activeSFTPClient()

        let localData: Data
        do {
            localData = try Data(contentsOf: localURL)
        } catch {
            throw RemoteFileServiceError.localFileUnreadable(url: localURL)
        }

        do {
            try await sftp.withFile(
                filePath: remoteAbsolutePath(for: path),
                flags: [.write, .create, .truncate]
            ) { file in
                try await file.write(ByteBuffer(bytes: localData))
            }
        } catch {
            throw Self.mapError(error, operation: String(localized: "上傳", bundle: .module), path: path)
        }
    }

    public func createDirectory(at path: String) async throws {
        let sftp = try activeSFTPClient()
        do {
            try await sftp.createDirectory(atPath: remoteAbsolutePath(for: path))
        } catch {
            throw Self.mapError(error, operation: String(localized: "建立目錄", bundle: .module), path: path)
        }
    }

    public func deleteFile(at path: String) async throws {
        let sftp = try activeSFTPClient()
        do {
            try await sftp.remove(at: remoteAbsolutePath(for: path))
        } catch {
            throw Self.mapError(error, operation: String(localized: "刪除檔案", bundle: .module), path: path)
        }
    }

    public func deleteDirectory(at path: String) async throws {
        // SFTP's RMDIR only removes an empty directory, so the tree is
        // emptied depth-first first.
        for child in try await listDirectory(at: path) {
            if child.isDirectory {
                try await deleteDirectory(at: child.path)
            } else {
                try await deleteFile(at: child.path)
            }
        }

        let sftp = try activeSFTPClient()
        do {
            try await sftp.rmdir(at: remoteAbsolutePath(for: path))
        } catch {
            throw Self.mapError(error, operation: String(localized: "刪除目錄", bundle: .module), path: path)
        }
    }

    public func moveItem(from oldPath: String, to newPath: String) async throws {
        let sftp = try activeSFTPClient()
        do {
            try await sftp.rename(
                at: remoteAbsolutePath(for: oldPath),
                to: remoteAbsolutePath(for: newPath)
            )
        } catch {
            throw Self.mapError(error, operation: String(localized: "移動", bundle: .module), path: oldPath)
        }
    }

    // MARK: - Helpers

    private func activeSFTPClient() throws -> SFTPClient {
        guard let sftpClient else {
            throw RemoteFileServiceError.notConnected
        }
        return sftpClient
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
        attributes: SFTPFileAttributes
    ) -> RemoteItem {
        RemoteItem(
            path: path,
            name: name,
            kind: kind(fromPermissions: attributes.permissions),
            size: Int64(attributes.size ?? 0),
            modificationDate: attributes.accessModificationTime?.modificationTime,
            creationDate: nil,
            permissions: attributes.permissions.map { UInt16($0 & 0o7777) }
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

    private static func mapError(_ error: Error, operation: String, path: String) -> Error {
        if let status = error as? SFTPMessage.Status, status.errorCode == .noSuchFile {
            log.debug("\(operation) at \(path): no such file")
            return RemoteFileServiceError.itemNotFound(path: path)
        }
        log.error("\(operation) at \(path) failed: \(String(describing: error))")
        return RemoteFileServiceError.operationFailed(
            operation: operation,
            path: path,
            underlying: String(describing: error)
        )
    }
}
