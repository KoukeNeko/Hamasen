import Foundation

/// A configured remote server. Passwords never live here — credentials go to
/// the Keychain only.
public struct ServerConfig: Codable, Identifiable, Hashable, Sendable {
    public enum TransferProtocol: String, Codable, Sendable, CaseIterable {
        case sftp
        // Phase 2: case ftp, case ftps
    }

    /// How the connection authenticates. The secret itself always lives in
    /// the Keychain; only the choice is stored here.
    public enum AuthenticationMethod: String, Codable, Sendable, CaseIterable {
        case password
        case privateKey

        public var displayName: String {
            switch self {
            case .password: return "密碼"
            case .privateKey: return "SSH 金鑰"
            }
        }
    }

    public static let defaultSFTPPort = 22
    public static let defaultRemotePath = RemotePath.root

    public let id: UUID
    public var name: String
    public var transferProtocol: TransferProtocol
    public var host: String
    public var port: Int
    public var username: String
    public var authenticationMethod: AuthenticationMethod
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
        authenticationMethod: AuthenticationMethod = .password,
        remotePath: String = ServerConfig.defaultRemotePath
    ) {
        self.id = id
        self.name = name
        self.transferProtocol = transferProtocol
        self.host = host
        self.port = port
        self.username = username
        self.authenticationMethod = authenticationMethod
        self.remotePath = ServerConfig.normalizedRemotePath(remotePath)
    }

    /// Configurations written before key authentication existed have no
    /// authenticationMethod field; they were all password-based.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.transferProtocol = try container.decode(TransferProtocol.self, forKey: .transferProtocol)
        self.host = try container.decode(String.self, forKey: .host)
        self.port = try container.decode(Int.self, forKey: .port)
        self.username = try container.decode(String.self, forKey: .username)
        self.authenticationMethod = try container.decodeIfPresent(
            AuthenticationMethod.self,
            forKey: .authenticationMethod
        ) ?? .password
        self.remotePath = try container.decode(String.self, forKey: .remotePath)
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
    /// An OpenSSH private key file, with the passphrase when it is encrypted.
    case privateKey(openSSHKey: String, passphrase: String?)
}
