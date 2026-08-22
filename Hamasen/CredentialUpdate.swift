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
