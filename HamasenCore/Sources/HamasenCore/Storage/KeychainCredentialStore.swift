import Foundation
import Security

/// Keychain access for server secrets.
///
/// Uses the Data Protection Keychain with the App Group as the access group
/// so both the main app and the File Provider extension can read and write
/// the same credentials.
public struct KeychainCredentialStore: Sendable {
    /// The kinds of secret a server can have. A server uses either a
    /// password or a private key (plus its passphrase when encrypted).
    public enum CredentialKind: String, Sendable, CaseIterable {
        case password
        case privateKey
        case keyPassphrase
    }

    public enum KeychainError: Error, Equatable {
        case itemNotFound
        case unexpectedData
        case operationFailed(status: OSStatus)
    }

    private let service: String
    private let accessGroup: String

    public init(
        service: String = SharedConstants.keychainService,
        accessGroup: String = SharedConstants.appGroupIdentifier
    ) {
        self.service = service
        self.accessGroup = accessGroup
    }

    // MARK: - Generic access

    public func save(_ secret: String, kind: CredentialKind, for serverID: UUID) throws {
        let secretData = Data(secret.utf8)
        var addQuery = baseQuery(for: serverID, kind: kind)
        addQuery[kSecValueData as String] = secretData

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                baseQuery(for: serverID, kind: kind) as CFDictionary,
                [kSecValueData as String: secretData] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw KeychainError.operationFailed(status: updateStatus)
            }
        } else if addStatus != errSecSuccess {
            throw KeychainError.operationFailed(status: addStatus)
        }
    }

    public func load(kind: CredentialKind, for serverID: UUID) throws -> String {
        var query = baseQuery(for: serverID, kind: kind)
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
        let status = SecItemDelete(baseQuery(for: serverID, kind: kind) as CFDictionary)
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

    private func baseQuery(for serverID: UUID, kind: CredentialKind) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: serverID, kind: kind),
            kSecAttrAccessGroup as String: accessGroup,
            // On macOS, App Group sharing only works with the Data
            // Protection Keychain.
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}
