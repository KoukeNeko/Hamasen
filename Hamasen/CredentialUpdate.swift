import Foundation
import HamasenCore

/// Secrets as entered in a server form. Empty or absent fields mean "leave
/// what is already in the Keychain alone", which is what lets the edit form
/// show a blank password field without wiping the stored one.
struct CredentialUpdate {
    var password: String = ""
    /// The contents of a newly imported key file; nil when unchanged.
    var privateKey: String?
    var keyPassphrase: String = ""

    /// Writes the entered secrets, leaving untouched fields as they are.
    func apply(to serverID: UUID, using store: KeychainCredentialStore) throws {
        if !password.isEmpty {
            try store.save(password, kind: .password, for: serverID)
        }
        if let privateKey {
            try store.save(privateKey, kind: .privateKey, for: serverID)
        }
        if !keyPassphrase.isEmpty {
            try store.save(keyPassphrase, kind: .keyPassphrase, for: serverID)
        }
    }

    /// Builds the credentials for a connection attempt, preferring what the
    /// user just entered and falling back to the stored secrets.
    func resolve(
        for config: ServerConfig,
        using store: KeychainCredentialStore
    ) throws -> ServerCredentials {
        switch config.authenticationMethod {
        case .password:
            if !password.isEmpty {
                return .password(password)
            }
            return .password(try store.load(kind: .password, for: config.id))
        case .privateKey:
            let key = try privateKey ?? store.load(kind: .privateKey, for: config.id)
            let passphrase = keyPassphrase.isEmpty
                ? try? store.load(kind: .keyPassphrase, for: config.id)
                : keyPassphrase
            return .privateKey(openSSHKey: key, passphrase: passphrase)
        }
    }
}
