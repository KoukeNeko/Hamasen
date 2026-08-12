import Foundation
import Security

/// Keychain access for server passwords.
///
/// Uses the Data Protection Keychain with the App Group as the access group
/// so both the main app and the File Provider extension can read and write
/// the same credentials.
public struct KeychainCredentialStore: Sendable {
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

    public func savePassword(_ password: String, for serverID: UUID) throws {
        let passwordData = Data(password.utf8)
        var addQuery = baseQuery(for: serverID)
        addQuery[kSecValueData as String] = passwordData

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                baseQuery(for: serverID) as CFDictionary,
                [kSecValueData as String: passwordData] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw KeychainError.operationFailed(status: updateStatus)
            }
        } else if addStatus != errSecSuccess {
            throw KeychainError.operationFailed(status: addStatus)
        }
    }

    public func loadPassword(for serverID: UUID) throws -> String {
        var query = baseQuery(for: serverID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { throw KeychainError.itemNotFound }
        guard status == errSecSuccess else { throw KeychainError.operationFailed(status: status) }
        guard let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedData
        }
        return password
    }

    public func deletePassword(for serverID: UUID) throws {
        let status = SecItemDelete(baseQuery(for: serverID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.operationFailed(status: status)
        }
    }

    private func baseQuery(for serverID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverID.uuidString,
            kSecAttrAccessGroup as String: accessGroup,
            // On macOS, App Group sharing only works with the Data
            // Protection Keychain.
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}
