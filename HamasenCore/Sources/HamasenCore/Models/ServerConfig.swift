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

/// A configured remote server. Passwords never live here — credentials go to
/// the Keychain only.
public struct ServerConfig: Codable, Identifiable, Hashable, Sendable {
    public enum TransferProtocol: String, Codable, Sendable, CaseIterable {
        case sftp
        case webdav
        case webdavs
        case ftp
        case ftps
        /// Every S3-compatible service: Cloudflare R2, Amazon, MinIO,
        /// Backblaze, Wasabi. One API and one signature serve all of them.
        case s3
        /// SMB 2 and 3: Windows shares and most NAS boxes on a local network.
        case smb
        /// Cloud drives, signed in to through the browser. None of them has a
        /// host to type: the host stored for them is their API's, and the
        /// username is the account that signed in.
        case googleDrive
        case oneDrive
        case dropbox

        public var displayName: String {
            switch self {
            case .sftp: return "SFTP"
            case .webdav: return "WebDAV"
            case .webdavs: return "WebDAV (HTTPS)"
            case .ftp: return "FTP"
            case .ftps: return "FTPS"
            case .s3: return "S3"
            case .smb: return "SMB"
            case .googleDrive: return String(localized: "Google 雲端硬碟", bundle: .module)
            case .oneDrive: return "OneDrive"
            case .dropbox: return "Dropbox"
            }
        }

        public var defaultPort: Int {
            switch self {
            case .sftp: return 22
            case .webdav: return 80
            case .webdavs: return 443
            case .ftp, .ftps: return 21
            case .s3: return 443
            case .smb: return 445
            case .googleDrive, .oneDrive, .dropbox: return 443
            }
        }

        /// The URL scheme for HTTP-based protocols; nil for SFTP, which does
        /// not address items by URL.
        public var urlScheme: String? {
            switch self {
            case .sftp: return nil
            case .webdav: return "http"
            case .webdavs: return "https"
            case .ftp, .ftps, .smb: return nil
            case .s3, .googleDrive, .oneDrive, .dropbox: return "https"
            }
        }

        /// The provider a cloud drive signs in with, or nil for a protocol
        /// that authenticates with a typed secret.
        public var oauthProvider: OAuthProvider? {
            switch self {
            case .googleDrive: return .google
            case .oneDrive: return .microsoft
            case .dropbox: return .dropbox
            case .sftp, .webdav, .webdavs, .ftp, .ftps, .s3, .smb: return nil
            }
        }

        /// Whether connections are made to a host the user names. Cloud
        /// drives have one fixed API host, which the form never shows.
        public var hasUserChosenHost: Bool { oauthProvider == nil }

        /// How often a new connection asks the server what changed.
        ///
        /// Off for S3, where every listing is billed and the person paying
        /// should be the one to switch it on. A minute for the cloud drives,
        /// whose APIs ration requests per account.
        public var defaultRemoteChangeIntervalSeconds: Int {
            switch self {
            case .s3: return 0
            case .googleDrive, .oneDrive, .dropbox: return 60
            case .sftp, .webdav, .webdavs, .ftp, .ftps, .smb: return 30
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
        /// A token from signing in through the browser; cloud drives only.
        case oauth

        public var displayName: String {
            switch self {
            case .password: return String(localized: "密碼", bundle: .module)
            case .privateKey: return String(localized: "SSH 金鑰", bundle: .module)
            case .oauth: return String(localized: "瀏覽器登入", bundle: .module)
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
    /// S3 only. nil reads the region out of the endpoint, which is where
    /// Amazon writes it and where nobody else has one to write.
    public var s3Region: String?
    /// S3 only. `.automatic` puts the bucket in the hostname for Amazon and
    /// in the path for everyone else, which is what R2 and MinIO need.
    public var s3AddressingStyle: S3AddressingStyle
    /// Whether the extension walks this server's tree in the background so
    /// Spotlight can index it. Every directory is one listing request, which
    /// on S3 is billed, so a server can decline.
    public var indexesInBackground: Bool
    /// Paused connections stay in Finder with whatever is already on this
    /// Mac, but nothing is sent to or fetched from the server until resumed.
    public var isPaused: Bool
    /// How often the app asks the server what changed, in seconds; 0 is
    /// never and nil the protocol's default.
    public var remoteChangeIntervalSeconds: Int?
    /// How the server's folder looks in Finder.
    public var finderAppearance: FinderAppearance

    /// The interval actually in force.
    public var effectiveRemoteChangeIntervalSeconds: Int {
        remoteChangeIntervalSeconds ?? transferProtocol.defaultRemoteChangeIntervalSeconds
    }

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
        cacheLimitBytes: Int64? = nil,
        s3Region: String? = nil,
        s3AddressingStyle: S3AddressingStyle = .automatic,
        indexesInBackground: Bool = true,
        isPaused: Bool = false,
        remoteChangeIntervalSeconds: Int? = nil,
        finderAppearance: FinderAppearance = FinderAppearance()
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
        self.s3Region = s3Region
        self.s3AddressingStyle = s3AddressingStyle
        self.indexesInBackground = indexesInBackground
        self.isPaused = isPaused
        self.remoteChangeIntervalSeconds = remoteChangeIntervalSeconds
        self.finderAppearance = finderAppearance
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
        // Added with S3. Every server saved before it has neither, and the
        // absent values are the ones that mean "work it out from the host".
        self.s3Region = try container.decodeIfPresent(String.self, forKey: .s3Region)
        self.s3AddressingStyle = try container.decodeIfPresent(
            S3AddressingStyle.self,
            forKey: .s3AddressingStyle
        ) ?? .automatic
        // On for servers saved before the setting existed: what they get is
        // Spotlight finding their files, which nobody had a reason to refuse.
        self.indexesInBackground = try container.decodeIfPresent(
            Bool.self, forKey: .indexesInBackground) ?? true
        // Both added with pausing and per-connection change checks; every
        // server saved before them was running, on the protocol's default.
        self.isPaused = try container.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
        self.remoteChangeIntervalSeconds = try container.decodeIfPresent(
            Int.self, forKey: .remoteChangeIntervalSeconds)
        // Added with folder customization; earlier servers kept Finder's look.
        // Only cosmetic, so one that cannot be read falls back to Finder's
        // look rather than taking the whole server list down with it.
        self.finderAppearance = (try? container.decodeIfPresent(
            FinderAppearance.self, forKey: .finderAppearance)) ?? FinderAppearance()
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
    /// What signing in to a cloud drive left behind, refreshed as it expires.
    case oauth(OAuthToken)
}
