import Foundation
import Security

/// Brings credentials written by an earlier build into the Data Protection
/// Keychain.
///
/// Builds before App Store distribution kept secrets in the file-based
/// Keychain, which needed no provisioning profile but which the File Provider
/// extension can only reach through an item ACL. Those items are copied, not
/// moved: a copy that turns out to be wrong costs nothing, while deleting the
/// only remaining copy of a password the user never wrote down costs them the
/// server.
public enum FileKeychainImport {
    private static let completedKey = "fileKeychainImportCompleted"
    private static let log = HamasenLog(category: "Migration")

    /// Copies anything found, once per installation. Returns how many items
    /// were brought across.
    @discardableResult
    public static func runIfNeeded(
        store: KeychainCredentialStore = KeychainCredentialStore(),
        defaults: UserDefaults = AppSettings.sharedStore
    ) -> Int {
        guard !defaults.bool(forKey: completedKey) else { return 0 }
        defaults.set(true, forKey: completedKey)

        let items = fileKeychainItems()
        guard !items.isEmpty else { return 0 }

        var imported = 0
        for (account, secret) in items {
            do {
                try store.save(secret, account: account)
                imported += 1
            } catch {
                log.error("Could not import credential \(account): \(error.localizedDescription)")
            }
        }
        log.notice("Imported \(imported) of \(items.count) credentials from the file-based Keychain")
        return imported
    }

    /// Every secret the older builds wrote, read straight out of the
    /// file-based Keychain. Absent `kSecUseDataProtectionKeychain`, this is
    /// the store these queries address.
    private static func fileKeychainItems() -> [(account: String, secret: Data)] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SharedConstants.keychainService,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let entries = result as? [[String: Any]]
        else { return [] }

        return entries.compactMap { entry in
            guard let account = entry[kSecAttrAccount as String] as? String,
                  let secret = entry[kSecValueData as String] as? Data
            else { return nil }
            return (account, secret)
        }
    }
}
