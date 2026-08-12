import Citadel
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

    private static let log = HamasenLog(category: "sftp")

    private let config: ServerConfig
    private let credentials: ServerCredentials
    private let connectTimeoutSeconds: Int
    private var sshClient: SSHClient?
    private var sftpClient: SFTPClient?

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
        guard sftpClient == nil else { return }

        Self.log.debug("Connecting to \(config.host):\(config.port) as \(config.username)")
        let client: SSHClient
        do {
            // Host keys are accepted blindly for the MVP (TOFU pinning is a
            // Phase 2 item) because there is no known-hosts store or user
            // confirmation UI yet.
            client = try await SSHClient.connect(
                host: config.host,
                port: config.port,
                authenticationMethod: makeAuthenticationMethod(),
                hostKeyValidator: .acceptAnything(),
                reconnect: .never,
                connectTimeout: .seconds(Int64(connectTimeoutSeconds))
            )
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

    public func disconnect() async throws {
        let sftp = sftpClient
        let ssh = sshClient
        sftpClient = nil
        sshClient = nil
        try? await sftp?.close()
        try await ssh?.close()
    }

    // MARK: - RemoteFileService

    public func listDirectory(at path: String) async throws -> [RemoteItem] {
        let sftp = try activeSFTPClient()
        let remoteDirectory = remoteAbsolutePath(for: path)

        let nameBatches: [SFTPMessage.Name]
        do {
            nameBatches = try await sftp.listDirectory(atPath: remoteDirectory)
        } catch {
            throw Self.mapError(error, operation: "列出目錄", path: path)
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
            throw Self.mapError(error, operation: "讀取屬性", path: path)
        }
    }

    public func downloadFile(at path: String, to localURL: URL) async throws {
        let sftp = try activeSFTPClient()
        // The MVP reads whole files into memory; streaming for large files is
        // a Phase 2 item.
        let buffer: ByteBuffer
        do {
            buffer = try await sftp.withFile(
                filePath: remoteAbsolutePath(for: path),
                flags: .read
            ) { file in
                try await file.readAll()
            }
        } catch {
            throw Self.mapError(error, operation: "下載", path: path)
        }

        let fileBytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) ?? []
        try Data(fileBytes).write(to: localURL, options: .atomic)
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
            throw Self.mapError(error, operation: "上傳", path: path)
        }
    }

    public func createDirectory(at path: String) async throws {
        let sftp = try activeSFTPClient()
        do {
            try await sftp.createDirectory(atPath: remoteAbsolutePath(for: path))
        } catch {
            throw Self.mapError(error, operation: "建立目錄", path: path)
        }
    }

    public func deleteFile(at path: String) async throws {
        let sftp = try activeSFTPClient()
        do {
            try await sftp.remove(at: remoteAbsolutePath(for: path))
        } catch {
            throw Self.mapError(error, operation: "刪除檔案", path: path)
        }
    }

    public func deleteDirectory(at path: String) async throws {
        let sftp = try activeSFTPClient()
        do {
            try await sftp.rmdir(at: remoteAbsolutePath(for: path))
        } catch {
            throw Self.mapError(error, operation: "刪除目錄", path: path)
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
            throw Self.mapError(error, operation: "移動", path: oldPath)
        }
    }

    // MARK: - Helpers

    private func activeSFTPClient() throws -> SFTPClient {
        guard let sftpClient else {
            throw RemoteFileServiceError.notConnected
        }
        return sftpClient
    }

    private func makeAuthenticationMethod() -> SSHAuthenticationMethod {
        switch credentials {
        case .password(let password):
            return .passwordBased(username: config.username, password: password)
        }
    }

    /// Maps a mount-relative path ("/docs/a.txt") to the remote absolute path
    /// (remotePath + relative path).
    private func remoteAbsolutePath(for mountRelativePath: String) -> String {
        let base = config.remotePath
        if base == RemotePath.root { return mountRelativePath }
        if mountRelativePath == RemotePath.root { return base }
        return base + mountRelativePath
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
