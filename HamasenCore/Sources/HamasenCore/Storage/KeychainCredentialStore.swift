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
import Security

/// Keychain access for server secrets.
///
/// Items live in the Data Protection Keychain under an access group both the
/// app and the File Provider extension are entitled to, which is how the
/// extension reads the credentials it connects with. That entitlement comes
/// from a provisioning profile, which App Store distribution provides.
///
/// Secrets are readable after the first unlock rather than only while the
/// screen is unlocked: the extension connects on the system's schedule, and
/// a mount that stops working until someone types their login password would
/// look broken rather than locked.
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

        public var errorDescription: String? {
            switch self {
            case .itemNotFound:
                return String(localized: "找不到 Keychain 憑證", bundle: .module)
            case .unexpectedData:
                return String(localized: "Keychain 憑證格式無法辨識", bundle: .module)
            case .operationFailed(let status):
                return String(localized: "Keychain 操作失敗（\(status): \(Self.message(for: status))）", bundle: .module)
            }
        }

        private static func message(for status: OSStatus) -> String {
            SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        }
    }

    private let service: String
    private let accessGroup: String

    public init(
        service: String = SharedConstants.keychainService,
        accessGroup: String = SharedConstants.keychainAccessGroup
    ) {
        self.service = service
        self.accessGroup = accessGroup
    }

    // MARK: - Generic access

    public func save(_ secret: String, kind: CredentialKind, for serverID: UUID) throws {
        try save(Data(secret.utf8), account: account(for: serverID, kind: kind))
    }

    /// Writes a secret, replacing whatever was there. Internal so the
    /// one-time import can move credentials without decoding them.
    func save(_ secretData: Data, account: String) throws {
        var addQuery = itemAttributes(account: account)
        addQuery[kSecValueData as String] = secretData
        addQuery[kSecAttrLabel as String] = Self.itemLabel
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                itemAttributes(account: account) as CFDictionary,
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
        var query = itemAttributes(account: account(for: serverID, kind: kind))
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
        let query = itemAttributes(account: account(for: serverID, kind: kind))
        let status = SecItemDelete(query as CFDictionary)
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

    static let itemLabel = "Hamasen server credential"

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

    private func itemAttributes(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            // Without this every query goes to the file-based keychain, which
            // is a different store holding different items.
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}
