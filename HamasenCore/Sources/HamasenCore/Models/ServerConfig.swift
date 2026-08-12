import Foundation

/// A configured remote server. Passwords never live here — credentials go to
/// the Keychain only.
public struct ServerConfig: Codable, Identifiable, Hashable, Sendable {
    public enum TransferProtocol: String, Codable, Sendable, CaseIterable {
        case sftp
        // Phase 2: case ftp, case ftps
    }

    public static let defaultSFTPPort = 22
    public static let defaultRemotePath = RemotePath.root

    public let id: UUID
    public var name: String
    public var transferProtocol: TransferProtocol
    public var host: String
    public var port: Int
    public var username: String
    /// Remote directory used as the mount root (e.g. "/home/user"); all paths
    /// inside the mount are resolved against it.
    public var remotePath: String

    public init(
        id: UUID = UUID(),
        name: String,
        transferProtocol: TransferProtocol = .sftp,
        host: String,
        port: Int = ServerConfig.defaultSFTPPort,
        username: String,
        remotePath: String = ServerConfig.defaultRemotePath
    ) {
        self.id = id
        self.name = name
        self.transferProtocol = transferProtocol
        self.host = host
        self.port = port
        self.username = username
        self.remotePath = ServerConfig.normalizedRemotePath(remotePath)
    }

    /// Normalizes remotePath: always starts with "/" and, except for the
    /// root itself, never ends with "/".
    public static func normalizedRemotePath(_ path: String) -> String {
        var normalized = path.trimmingCharacters(in: .whitespaces)
        if normalized.isEmpty { return RemotePath.root }
        if !normalized.hasPrefix(RemotePath.separator) {
            normalized = RemotePath.separator + normalized
        }
        while normalized.count > 1 && normalized.hasSuffix(RemotePath.separator) {
            normalized.removeLast()
        }
        return normalized
    }
}

/// Credentials used to authenticate a connection. Kept separate from
/// ServerConfig so they can never be serialized into the config file by
/// accident.
public enum ServerCredentials: Sendable {
    case password(String)
    // Phase 2: case privateKey(pem: String, passphrase: String?)
}
