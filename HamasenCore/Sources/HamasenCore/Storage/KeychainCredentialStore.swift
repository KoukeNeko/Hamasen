import Foundation
import Security

/// Keychain access for server secrets.
///
/// Uses the macOS file-based Keychain with an item ACL that trusts both the
/// main app and the File Provider extension. This avoids a distribution-only
/// provisioning profile: Data Protection Keychain sharing requires the
/// restricted `keychain-access-groups` entitlement, while a local Developer
/// ID build can express the same trust with `SecAccess`.
public struct KeychainCredentialStore: Sendable {
    /// The kinds of secret a server can have. A server uses either a
    /// password or a private key (plus its passphrase when encrypted).
    public enum CredentialKind: String, Sendable, CaseIterable {
        case password
        case privateKey
        case keyPassphrase
    }

    public enum KeychainError: LocalizedError, Equatable {
        case itemNotFound
        case unexpectedData
        case operationFailed(status: OSStatus)
        case trustedApplicationUnavailable(path: String, status: OSStatus)
        case accessCreationFailed(status: OSStatus)

        public var errorDescription: String? {
            switch self {
            case .itemNotFound:
                return String(localized: "找不到 Keychain 憑證", bundle: .module)
            case .unexpectedData:
                return String(localized: "Keychain 憑證格式無法辨識", bundle: .module)
            case .operationFailed(let status):
                return String(localized: "Keychain 操作失敗（\(status): \(Self.message(for: status))）", bundle: .module)
            case .trustedApplicationUnavailable(let path, let status):
                return String(localized: "無法建立受信任程式 \(path)（\(status): \(Self.message(for: status))）", bundle: .module)
            case .accessCreationFailed(let status):
                return String(localized: "無法建立 Keychain ACL（\(status): \(Self.message(for: status))）", bundle: .module)
            }
        }

        private static func message(for status: OSStatus) -> String {
            SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        }
    }

    private let service: String
    private let trustedApplicationURLs: [URL]?

    public init(
        service: String = SharedConstants.keychainService,
        trustedApplicationURLs: [URL]? = nil
    ) {
        self.service = service
        self.trustedApplicationURLs = trustedApplicationURLs
    }

    // MARK: - Generic access

    public func save(_ secret: String, kind: CredentialKind, for serverID: UUID) throws {
        try save(Data(secret.utf8), account: account(for: serverID, kind: kind))
    }

    /// Imports an existing item while preserving its account naming scheme.
    /// Internal so the one-time migration can move credentials without ever
    /// decoding or logging their contents.
    func save(_ secretData: Data, account: String) throws {
        var addQuery = itemAttributes(account: account)
        addQuery[kSecUseKeychain as String] = try defaultKeychain()
        addQuery[kSecValueData as String] = secretData
        addQuery[kSecAttrLabel as String] = "Hamasen server credential"
        addQuery[kSecAttrAccess as String] = try makeSharedAccess()

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                try searchQuery(account: account) as CFDictionary,
                [kSecValueData as String: secretData] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw KeychainError.operationFailed(status: updateStatus)
            }
        } else if addStatus != errSecSuccess {
            throw KeychainError.operationFailed(status: addStatus)
        }
    }

    /// Imports a migration item only when the destination is absent. Existing
    /// file-based items are never edited by the development-signed helper.
    @discardableResult
    func insertForMigration(_ secretData: Data, account: String) throws -> Bool {
        var addQuery = itemAttributes(account: account)
        addQuery[kSecUseKeychain as String] = try defaultKeychain()
        addQuery[kSecValueData as String] = secretData
        addQuery[kSecAttrLabel as String] = "Hamasen server credential"
        addQuery[kSecAttrAccess as String] = try makeSharedAccess()

        switch SecItemAdd(addQuery as CFDictionary, nil) {
        case errSecSuccess:
            return true
        case errSecDuplicateItem:
            return false
        case let status:
            throw KeychainError.operationFailed(status: status)
        }
    }

    /// Removes one migration-created file-based item. This is called only by
    /// the already-installed, ACL-trusted final app during installer rollback.
    func delete(account: String) throws {
        let status = SecItemDelete(try searchQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.operationFailed(status: status)
        }
    }

    public func load(kind: CredentialKind, for serverID: UUID) throws -> String {
        var query = try searchQuery(for: serverID, kind: kind)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { throw KeychainError.itemNotFound }
        guard status == errSecSuccess else { throw KeychainError.operationFailed(status: status) }
        guard let data = result as? Data, let secret = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedData
        }
        return secret
    }

    public func delete(kind: CredentialKind, for serverID: UUID) throws {
        let status = SecItemDelete(try searchQuery(for: serverID, kind: kind) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.operationFailed(status: status)
        }
    }

    /// Removes every secret belonging to a server, used when it is deleted.
    public func deleteAllCredentials(for serverID: UUID) throws {
        for kind in CredentialKind.allCases {
            try delete(kind: kind, for: serverID)
        }
    }

    // MARK: - Connection credentials

    /// Assembles the credentials a connection needs, based on the server's
    /// configured authentication method.
    public func loadCredentials(for config: ServerConfig) throws -> ServerCredentials {
        switch config.authenticationMethod {
        case .password:
            return .password(try load(kind: .password, for: config.id))
        case .privateKey:
            let openSSHKey = try load(kind: .privateKey, for: config.id)
            let passphrase = try? load(kind: .keyPassphrase, for: config.id)
            return .privateKey(openSSHKey: openSSHKey, passphrase: passphrase)
        }
    }

    // MARK: - Query building

    /// Passwords keep the bare server identifier as their account so
    /// credentials saved before key authentication existed stay readable;
    /// the newer kinds are suffixed.
    private func account(for serverID: UUID, kind: CredentialKind) -> String {
        switch kind {
        case .password:
            return serverID.uuidString
        case .privateKey, .keyPassphrase:
            return "\(serverID.uuidString).\(kind.rawValue)"
        }
    }

    private func searchQuery(for serverID: UUID, kind: CredentialKind) throws -> [String: Any] {
        try searchQuery(account: account(for: serverID, kind: kind))
    }

    private func searchQuery(account: String) throws -> [String: Any] {
        var query = itemAttributes(account: account)
        // Never search every keychain in the user's search list. This pins
        // reads, updates, and deletes to the same Keychain used by save.
        query[kSecMatchSearchList as String] = [try defaultKeychain()]
        return query
    }

    private func itemAttributes(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func defaultKeychain() throws -> SecKeychain {
        var keychain: SecKeychain?
        let status = SecKeychainCopyDefault(&keychain)
        guard status == errSecSuccess, let keychain else {
            throw KeychainError.operationFailed(status: status)
        }
        return keychain
    }

    /// Builds the ACL at creation time; changing it later would require a
    /// user authorization prompt. Explicit URLs are used by the installer to
    /// trust the final Developer ID app even though migration runs from a
    /// development-signed build.
    private func makeSharedAccess() throws -> SecAccess {
        var trustedApplications: [SecTrustedApplication] = []
        let applicationURLs = trustedApplicationURLs ?? Self.defaultTrustedApplicationURLs()
        guard !applicationURLs.isEmpty else {
            throw KeychainError.trustedApplicationUnavailable(path: "<application bundle>", status: errSecParam)
        }
        for url in applicationURLs {
            var application: SecTrustedApplication?
            let status = url.path.withCString {
                SecTrustedApplicationCreateFromPath($0, &application)
            }
            guard status == errSecSuccess, let application else {
                throw KeychainError.trustedApplicationUnavailable(path: url.path, status: status)
            }
            trustedApplications.append(application)
        }

        var access: SecAccess?
        let status = SecAccessCreate(
            "Hamasen server credential" as CFString,
            trustedApplications as CFArray,
            &access
        )
        guard status == errSecSuccess, let access else {
            throw KeychainError.accessCreationFailed(status: status)
        }
        return access
    }

    /// Returns the app and embedded File Provider bundle URLs regardless of
    /// whether the code is currently running in the app or the extension.
    private static func defaultTrustedApplicationURLs() -> [URL] {
        let currentBundleURL = Bundle.main.bundleURL.standardizedFileURL
        let appURL: URL
        if currentBundleURL.pathExtension == "app" {
            appURL = currentBundleURL
        } else if currentBundleURL.pathExtension == "appex" {
            appURL = currentBundleURL
                .deletingLastPathComponent() // PlugIns
                .deletingLastPathComponent() // Contents
                .deletingLastPathComponent() // Hamasen.app
        } else {
            return []
        }

        let providerURL = appURL
            .appendingPathComponent("Contents/PlugIns/HamasenFileProvider.appex", isDirectory: true)
        return [appURL, providerURL].filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }
}
