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

import HamasenCore
import SwiftUI

/// A connection as it is being typed: every field either form shows, the
/// rules for turning them into a configuration, and the secrets to store.
///
/// One type for adding and editing, so a field that exists in one of them
/// exists in the other — a setting the person can create and then never see
/// again is the failure this prevents.
struct ConnectionDraft {
    let id: UUID
    let kind: ServiceKind

    var name: String
    var transferProtocol: ServerConfig.TransferProtocol
    /// The host, or for WebDAV the whole URL, as typed.
    var address: String
    var portText: String
    var username: String
    var remotePath: String
    /// SMB only: the share, which the configuration keeps as the first
    /// component of the remote path.
    var share: String

    var authenticationMethod: ServerConfig.AuthenticationMethod
    var password = ""
    var importedKey: PrivateKeyImporter.ImportedKey?
    var keyPassphrase = ""
    /// The key an imported SSH configuration names, which the key panel
    /// opens on; the sandbox cannot read it until it is chosen there.
    var suggestedKeyPath: String?
    var oauthToken: OAuthToken?

    var storageMode: ServerConfig.StorageMode
    var cacheAllowance: CacheAllowance
    var s3Region: String
    var s3AddressingStyle: S3AddressingStyle
    var indexesInBackground: Bool
    var remoteChangeInterval: RemoteChangeInterval
    var isPaused: Bool

    init(kind: ServiceKind) {
        let transferProtocol = kind.defaultProtocol
        id = UUID()
        self.kind = kind
        name = ""
        self.transferProtocol = transferProtocol
        address = ""
        portText = String(transferProtocol == .sftp ? AppSettings.defaultServerPort() : transferProtocol.defaultPort)
        username = ""
        remotePath = transferProtocol == .s3 ? "" : ServerConfig.defaultRemotePath
        share = ""
        authenticationMethod = transferProtocol.oauthProvider == nil ? .password : .oauth
        storageMode = .automatic
        cacheAllowance = .unlimited
        s3Region = ""
        s3AddressingStyle = .automatic
        indexesInBackground = transferProtocol != .s3
        remoteChangeInterval = RemoteChangeInterval(seconds: transferProtocol.defaultRemoteChangeIntervalSeconds)
        isPaused = false
    }

    init(server: ServerConfig) {
        id = server.id
        kind = server.serviceKind
        name = server.name
        transferProtocol = server.transferProtocol
        address = server.serviceKind == .webdav ? ServerAddress.webDAVURL(for: server) : server.host
        portText = String(server.port)
        username = server.username
        if server.transferProtocol == .smb, let location = SMBFileService.location(of: server.remotePath) {
            share = location.share
            remotePath = location.directory.isEmpty ? RemotePath.root : "/" + location.directory
        } else {
            share = ""
            remotePath = server.remotePath
        }
        authenticationMethod = server.authenticationMethod
        storageMode = server.storageMode
        cacheAllowance = CacheAllowance(bytes: server.cacheLimitBytes)
        s3Region = server.s3Region ?? ""
        s3AddressingStyle = server.s3AddressingStyle
        indexesInBackground = server.indexesInBackground
        remoteChangeInterval = RemoteChangeInterval(seconds: server.effectiveRemoteChangeIntervalSeconds)
        isPaused = server.isPaused
    }

    /// Fills in what an SSH configuration says about one of its hosts,
    /// leaving fields it does not mention as they are.
    mutating func apply(_ host: SSHConfigHost) {
        address = host.hostName ?? host.alias
        if let port = host.port { portText = String(port) }
        if let user = host.user { username = user }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { name = host.alias }
        if let identityFile = host.identityFile {
            authenticationMethod = .privateKey
            suggestedKeyPath = identityFile
        }
    }

    // MARK: - Turning it into a configuration

    private var parsedAddress: ServerAddress? { ServerAddress.parse(address) }

    /// The protocol the fields add up to: WebDAV's scheme comes from the URL
    /// typed.
    private var effectiveProtocol: ServerConfig.TransferProtocol {
        guard kind == .webdav else { return transferProtocol }
        return parsedAddress?.scheme == "http" ? .webdav : .webdavs
    }

    private var effectiveHost: String? {
        if let provider = transferProtocol.oauthProvider { return provider.apiHost }
        guard let host = parsedAddress?.host, !host.isEmpty else { return nil }
        return host
    }

    private var effectivePort: Int? {
        if transferProtocol.oauthProvider != nil { return transferProtocol.defaultPort }
        if kind == .webdav {
            return parsedAddress?.port ?? effectiveProtocol.defaultPort
        }
        // A port pasted with the host wins over the field, which still holds
        // the default nobody edited.
        if let pasted = parsedAddress?.port { return pasted }
        guard let port = Int(portText.trimmingCharacters(in: .whitespaces)),
              ServerConfig.validPortRange.contains(port)
        else { return nil }
        return port
    }

    private var effectiveRemotePath: String {
        switch kind {
        case .webdav:
            return parsedAddress?.path ?? RemotePath.root
        case .smb:
            let share = self.share.trimmingCharacters(in: CharacterSet(charactersIn: "/\\").union(.whitespaces))
            let inside = ServerConfig.normalizedRemotePath(remotePath)
            return inside == RemotePath.root ? "/" + share : "/" + share + inside
        default:
            return ServerConfig.normalizedRemotePath(remotePath)
        }
    }

    private var effectiveUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The name used when none was typed: what the person would call it
    /// anyway.
    var suggestedName: String {
        if transferProtocol.oauthProvider != nil {
            return effectiveUsername.isEmpty ? kind.title : "\(kind.title)（\(effectiveUsername)）"
        }
        return effectiveHost ?? kind.title
    }

    /// The configuration the fields describe, or nil while something needed
    /// is missing or cannot work.
    func makeConfig() -> ServerConfig? {
        guard let host = effectiveHost, let port = effectivePort else { return nil }
        let protocolValue = effectiveProtocol
        if protocolValue.oauthProvider == nil, effectiveUsername.isEmpty, kind != .webdav, kind != .smb {
            return nil
        }
        if kind == .smb, share.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        guard S3ServerFields.namesABucket(effectiveRemotePath, transferProtocol: protocolValue) else { return nil }
        let typedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return ServerConfig(
            id: id,
            name: typedName.isEmpty ? suggestedName : typedName,
            transferProtocol: protocolValue,
            host: host,
            port: port,
            username: effectiveUsername,
            authenticationMethod: protocolValue.oauthProvider == nil ? authenticationMethod : .oauth,
            remotePath: effectiveRemotePath,
            storageMode: storageMode,
            cacheLimitBytes: cacheAllowance.bytes,
            s3Region: s3Region.trimmingCharacters(in: .whitespaces),
            s3AddressingStyle: s3AddressingStyle,
            indexesInBackground: indexesInBackground,
            isPaused: isPaused,
            remoteChangeIntervalSeconds: remoteChangeInterval.rawValue
                == protocolValue.defaultRemoteChangeIntervalSeconds ? nil : remoteChangeInterval.rawValue
        )
    }

    /// The secrets typed or signed in to; empty fields leave what is stored.
    var credentials: CredentialUpdate {
        // Only the secret the chosen method actually uses is written, so a
        // key kept for a possible switch back never lands in the Keychain of
        // a password-authenticated server.
        switch makeConfig()?.authenticationMethod ?? authenticationMethod {
        case .password:
            return CredentialUpdate(password: password)
        case .privateKey:
            return CredentialUpdate(privateKey: importedKey?.text, keyPassphrase: keyPassphrase)
        case .oauth:
            return CredentialUpdate(oauthToken: oauthToken)
        }
    }

    /// Whether something new was typed for a secret, which makes an
    /// otherwise unchanged draft worth saving.
    var hasNewSecrets: Bool {
        !password.isEmpty || importedKey != nil || !keyPassphrase.isEmpty || oauthToken != nil
    }

    /// Whether the chosen method has a secret to use, typed now or stored.
    func hasUsableCredential(hasStoredPassword: Bool, hasStoredKey: Bool, hasStoredToken: Bool) -> Bool {
        switch makeConfig()?.authenticationMethod ?? authenticationMethod {
        case .password:
            return !password.isEmpty || hasStoredPassword
        case .privateKey:
            return importedKey != nil || hasStoredKey
        case .oauth:
            return oauthToken != nil || hasStoredToken
        }
    }
}

/// The intervals offered for checking a server for changes.
enum RemoteChangeInterval: Int, CaseIterable, Identifiable {
    case off = 0
    case thirtySeconds = 30
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case oneHour = 3_600

    var id: Int { rawValue }

    init(seconds: Int) {
        self = Self(rawValue: seconds) ?? Self.allCases.first { $0.rawValue >= seconds } ?? .oneHour
    }

    var title: String {
        switch self {
        case .off: return String(localized: "不檢查")
        case .thirtySeconds: return String(localized: "每 30 秒")
        case .oneMinute: return String(localized: "每分鐘")
        case .fiveMinutes: return String(localized: "每 5 分鐘")
        case .fifteenMinutes: return String(localized: "每 15 分鐘")
        case .oneHour: return String(localized: "每小時")
        }
    }
}
