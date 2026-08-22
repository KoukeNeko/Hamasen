import Foundation

/// A configured remote server. Passwords never live here — credentials go to
/// the Keychain only.
public struct ServerConfig: Codable, Identifiable, Hashable, Sendable {
    public enum TransferProtocol: String, Codable, Sendable, CaseIterable {
        case sftp
        case webdav
        case webdavs
        case ftp
        case ftps

        public var displayName: String {
            switch self {
            case .sftp: return "SFTP"
            case .webdav: return "WebDAV"
            case .webdavs: return "WebDAV (HTTPS)"
            case .ftp: return "FTP"
            case .ftps: return "FTPS"
            }
        }

        public var defaultPort: Int {
            switch self {
            case .sftp: return 22
            case .webdav: return 80
            case .webdavs: return 443
            case .ftp, .ftps: return 21
            }
        }

        /// The URL scheme for HTTP-based protocols; nil for SFTP, which does
        /// not address items by URL.
        public var urlScheme: String? {
            switch self {
            case .sftp: return nil
            case .webdav: return "http"
            case .webdavs: return "https"
            case .ftp, .ftps: return nil
            }
        }

        /// Whether the protocol authenticates with an SSH key rather than a
        /// password.
        public var supportsPrivateKeyAuthentication: Bool {
            self == .sftp
        }

        /// Whether credentials and contents cross the network readable by
        /// anyone carrying them. Only plain FTP and plain WebDAV do; it is
        /// worth saying so where the choice is made.
        public var isUnencrypted: Bool {
            self == .ftp || self == .webdav
        }
    }

    /// How the connection authenticates. The secret itself always lives in
    /// the Keychain; only the choice is stored here.
    public enum AuthenticationMethod: String, Codable, Sendable, CaseIterable {
        case password
        case privateKey

        public var displayName: String {
            switch self {
            case .password: return String(localized: "密碼", bundle: .module)
            case .privateKey: return String(localized: "SSH 金鑰", bundle: .module)
            }
        }
    }

    /// Whether the system may keep a server's content on this Mac.
    ///
    /// A File Provider always materializes what is read — the content cannot
    /// stay entirely on the server — so "online only" means it does not
    /// linger: the system is told to drop it when the remote copy changes,
    /// and the extension evicts what is no longer in use.
    public enum StorageMode: String, Codable, Sendable, CaseIterable {
        /// The system decides, keeping content until it needs the space.
        case automatic
        /// Content is dropped as soon as it is no longer needed.
        case onlineOnly

        public var displayName: String {
            switch self {
            case .automatic: return String(localized: "自動", bundle: .module)
            case .onlineOnly: return String(localized: "純線上", bundle: .module)
            }
        }
    }

    public static let defaultSFTPPort = TransferProtocol.sftp.defaultPort
    public static let defaultRemotePath = RemotePath.root
    public static let validPortRange = 1...65535

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
    /// Whether this server's content may stay on the Mac.
    public var storageMode: StorageMode
    /// How much of it may stay, in bytes; nil leaves it to the system.
    /// Ignored while the mode is online only, which keeps nothing anyway.
    public var cacheLimitBytes: Int64?

    public init(
        id: UUID = UUID(),
        name: String,
        transferProtocol: TransferProtocol = .sftp,
        host: String,
        port: Int = ServerConfig.defaultSFTPPort,
        username: String,
        authenticationMethod: AuthenticationMethod = .password,
        remotePath: String = ServerConfig.defaultRemotePath,
        storageMode: StorageMode = .automatic,
        cacheLimitBytes: Int64? = nil
    ) {
        self.id = id
        self.name = name
        self.transferProtocol = transferProtocol
        self.host = host
        self.port = port
        self.username = username
        self.authenticationMethod = authenticationMethod
        self.remotePath = ServerConfig.normalizedRemotePath(remotePath)
        self.storageMode = storageMode
        self.cacheLimitBytes = cacheLimitBytes
    }

    /// Configurations written before key authentication existed have no
    /// authenticationMethod field; they were all password-based.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.transferProtocol = try container.decode(TransferProtocol.self, forKey: .transferProtocol)
        self.host = try container.decode(String.self, forKey: .host)
        // Clamped on the way in: an out-of-range port reaches URLComponents,
        // which traps rather than throwing, crashing the extension.
        let decodedPort = try container.decode(Int.self, forKey: .port)
        self.port = ServerConfig.validPortRange.contains(decodedPort)
            ? decodedPort
            : ServerConfig.defaultSFTPPort
        self.username = try container.decode(String.self, forKey: .username)
        self.authenticationMethod = try container.decodeIfPresent(
            AuthenticationMethod.self,
            forKey: .authenticationMethod
        ) ?? .password
        self.remotePath = ServerConfig.normalizedRemotePath(
            try container.decode(String.self, forKey: .remotePath)
        )
        // Written before the storage mode existed: the system decided then,
        // which is what .automatic means.
        self.storageMode = try container.decodeIfPresent(
            StorageMode.self,
            forKey: .storageMode
        ) ?? .automatic
        // Absent before a limit could be set, and absent again whenever the
        // user chooses not to have one.
        self.cacheLimitBytes = try container.decodeIfPresent(Int64.self, forKey: .cacheLimitBytes)
    }

    /// What makes two entries the same connection.
    ///
    /// The name is left out on purpose: renaming a server does not make it
    /// another one, and an import that added a second copy under a new name
    /// would be worse than one that skipped it.
    public var connectionIdentity: String {
        [
            transferProtocol.rawValue,
            host.lowercased(),
            String(port),
            username,
            remotePath,
        ].joined(separator: "\u{0}")
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
