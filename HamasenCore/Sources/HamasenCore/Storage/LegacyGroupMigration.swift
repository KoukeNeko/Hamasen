import Foundation
import Security

/// One-time move of stored data out of the legacy "group.*" App Group into
/// the team-prefixed one, and of credentials into the file-based Keychain.
///
/// The group changed because pkd only enables the FinderSync extension for
/// Developer ID-signed builds, and under Developer ID a "group.*" group
/// demands a provisioning profile while a team-prefixed one does not. Only
/// development builds still carry the legacy groups in their entitlements, so
/// the installer runs this migration from that build before launching the
/// Developer ID app.
public enum LegacyGroupMigration {
    // v3 migrates credentials out of the entitlement-mediated Data Protection
    // Keychain and into file-based items with an app + extension ACL.
    private static let completedMarkerKey = "legacyGroupMigrationCompleted.v3"
    private static let pendingCredentialAccountsKey = "legacyGroupMigrationPendingAccounts.v3"
    private static let log = HamasenLog(category: "Migration")

    /// Installer-only migration. Normal app launches never invoke this path.
    ///
    /// Returns whether migration is complete. The Developer ID installer uses
    /// a development-signed build and passes the final installed app URL so
    /// the new Keychain ACL trusts the distribution binaries.
    @discardableResult
    public static func runIfNeeded(
        credentialConsumerAppURL: URL? = nil,
        force: Bool = false
    ) -> Bool {
        guard force,
              let credentialConsumerAppURL,
              validateCredentialConsumerApp(at: credentialConsumerAppURL)
        else {
            log.error("Rejected a non-installer or invalid migration request")
            return false
        }
        let newDefaults = AppSettings.sharedStore
        guard !newDefaults.bool(forKey: completedMarkerKey) else { return true }

        let fileTransfersDone = migrateStoreFiles()
        let settingsDone = migrateSharedSettings(into: newDefaults)
        let keychainDone = migrateKeychainItems(
            credentialConsumerAppURL: credentialConsumerAppURL
        )

        // Completion is committed by the installed app only after it proves it
        // can read every credential through the final ACL.
        return fileTransfersDone && settingsDone && keychainDone
    }

    // MARK: - Config files

    private static func migrateStoreFiles() -> Bool {
        guard
            let legacyContainer = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: SharedConstants.legacyAppGroupIdentifier
            ),
            let newContainer = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: SharedConstants.appGroupIdentifier
            )
        else {
            // A Developer ID build intentionally cannot see the legacy group.
            // Do not mark migration complete: a development-signed build with
            // both groups may still migrate the data later.
            return false
        }

        let migrationAlreadyComplete = AppSettings.sharedStore.bool(forKey: completedMarkerKey)
        var allSucceeded = true
        let fileNames = [
            SharedConstants.serverConfigFileName,
            SharedConstants.mountedServersFileName,
        ]
        for fileName in fileNames {
            let source = legacyContainer.appendingPathComponent(fileName)
            let destination = newContainer.appendingPathComponent(fileName)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }

            // Before the all-or-nothing marker is committed, a retry must
            // refresh files copied by an earlier failed install. Once complete,
            // the new group owns subsequent user edits and is never overwritten.
            if FileManager.default.fileExists(atPath: destination.path) {
                guard !migrationAlreadyComplete else { continue }
                do {
                    try FileManager.default.removeItem(at: destination)
                } catch {
                    log.error("Preparing \(fileName) for retry failed: \(error.localizedDescription)")
                    allSucceeded = false
                    continue
                }
            }

            do {
                try FileManager.default.copyItem(at: source, to: destination)
                log.debug("Migrated \(fileName)")
            } catch {
                log.error("Migrating \(fileName) failed: \(error.localizedDescription)")
                allSucceeded = false
            }
        }
        return allSucceeded
    }

    // MARK: - Shared settings

    private static func migrateSharedSettings(into newDefaults: UserDefaults) -> Bool {
        guard let legacyDefaults = UserDefaults(
            suiteName: SharedConstants.legacyAppGroupIdentifier
        ) else { return true }

        let sharedSettingKeys = [
            AppSettings.Keys.connectTimeoutSeconds,
            AppSettings.Keys.defaultServerPort,
            AppSettings.Keys.debugLoggingEnabled,
        ]
        let migrationAlreadyComplete = newDefaults.bool(forKey: completedMarkerKey)
        for key in sharedSettingKeys {
            guard !migrationAlreadyComplete,
                  let legacyValue = legacyDefaults.object(forKey: key)
            else { continue }
            newDefaults.set(legacyValue, forKey: key)
        }
        return true
    }

    // MARK: - Keychain

    private static func migrateKeychainItems(credentialConsumerAppURL: URL?) -> Bool {
        let trustedApplicationURLs: [URL]?
        if let appURL = credentialConsumerAppURL {
            trustedApplicationURLs = [
                appURL,
                appURL.appendingPathComponent(
                    "Contents/PlugIns/HamasenFileProvider.appex",
                    isDirectory: true
                ),
            ]
        } else {
            trustedApplicationURLs = nil
        }
        let destination = KeychainCredentialStore(
            trustedApplicationURLs: trustedApplicationURLs
        )
        var allSucceeded = true
        var migratedCount = 0
        var seenAccounts = Set<String>()
        var insertedAccounts = Set(
            AppSettings.sharedStore.stringArray(forKey: pendingCredentialAccountsKey) ?? []
        )

        // Newest to oldest: the first available source wins on initial import.
        // Once the file-based destination exists it always wins, so a later
        // installer run cannot restore a stale password over a user edit.
        for accessGroup in SharedConstants.migratedKeychainAccessGroupIdentifiers.reversed() {
            let copyQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: SharedConstants.keychainService,
                kSecAttrAccessGroup as String: accessGroup,
                kSecUseDataProtectionKeychain as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll,
                kSecReturnAttributes as String: true,
                kSecReturnData as String: true,
            ]

            var found: CFTypeRef?
            let copyStatus = SecItemCopyMatching(copyQuery as CFDictionary, &found)
            switch copyStatus {
            case errSecSuccess:
                break
            case errSecItemNotFound:
                continue
            case errSecMissingEntitlement:
                // A Developer ID build cannot prove that this source is empty;
                // leave the marker unset so the installer helper can retry.
                allSucceeded = false
                continue
            default:
                log.error("Reading a migration Keychain group failed: \(copyStatus)")
                allSucceeded = false
                continue
            }

            guard let items = found as? [[String: Any]] else { continue }
            for item in items {
                guard let account = item[kSecAttrAccount as String] as? String,
                      let secretData = item[kSecValueData as String] as? Data,
                      seenAccounts.insert(account).inserted
                else { continue }
                do {
                    if try destination.insertForMigration(secretData, account: account) {
                        migratedCount += 1
                        insertedAccounts.insert(account)
                        AppSettings.sharedStore.set(
                            insertedAccounts.sorted(),
                            forKey: pendingCredentialAccountsKey
                        )
                    }
                } catch {
                    log.error("Writing a file-based Keychain item failed: \(error.localizedDescription)")
                    allSucceeded = false
                }
            }
        }
        log.debug("Migrated \(migratedCount) Keychain item copies")
        return allSucceeded
    }

    /// Rolls back only credentials created by a failed, uncommitted migration.
    /// The final installed app owns their ACL, so it can remove them without
    /// widening trust to the development-signed migration helper.
    public static func rollbackUncommittedCredentials() -> Bool {
        guard !AppSettings.sharedStore.bool(forKey: completedMarkerKey) else { return true }
        let destination = KeychainCredentialStore()
        var allSucceeded = true
        let accounts = AppSettings.sharedStore.stringArray(
            forKey: pendingCredentialAccountsKey
        ) ?? []
        for account in accounts {
            do {
                try destination.delete(account: account)
            } catch {
                allSucceeded = false
            }
        }
        if allSucceeded {
            AppSettings.sharedStore.removeObject(forKey: pendingCredentialAccountsKey)
        }
        return allSucceeded
    }

    /// Commits the two-phase migration after the final app's readback probe.
    public static func finalizeMigration() {
        AppSettings.sharedStore.removeObject(forKey: pendingCredentialAccountsKey)
        AppSettings.sharedStore.set(true, forKey: completedMarkerKey)
        log.debug("Legacy App Group migration completed")
    }

    /// The migration helper is development-signed and can read legacy secrets,
    /// so it may grant ACL access only to the exact installed, signed bundles.
    private static func validateCredentialConsumerApp(at suppliedURL: URL) -> Bool {
        let expectedAppURL = URL(
            fileURLWithPath: "/Applications/Hamasen.app",
            isDirectory: true
        ).resolvingSymlinksInPath().standardizedFileURL
        let appURL = suppliedURL.resolvingSymlinksInPath().standardizedFileURL
        guard appURL == expectedAppURL else { return false }

        let providerURL = appURL.appendingPathComponent(
            "Contents/PlugIns/HamasenFileProvider.appex",
            isDirectory: true
        )
        return validateSignedBundle(
            at: appURL,
            bundleIdentifier: "dev.hamasen.mac"
        ) && validateSignedBundle(
            at: providerURL,
            bundleIdentifier: "dev.hamasen.mac.FileProvider"
        )
    }

    private static func validateSignedBundle(at url: URL, bundleIdentifier: String) -> Bool {
        guard Bundle(url: url)?.bundleIdentifier == bundleIdentifier else { return false }

        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code
        else { return false }

        let requirementText = "anchor apple generic and identifier \"\(bundleIdentifier)\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"33832Z66QU\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            requirementText as CFString,
            [],
            &requirement
        ) == errSecSuccess, let requirement
        else { return false }

        return SecStaticCodeCheckValidity(
            code,
            SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate),
            requirement
        ) == errSecSuccess
    }
}
