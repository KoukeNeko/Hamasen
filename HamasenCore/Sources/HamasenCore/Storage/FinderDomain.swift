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

import FileProvider
import Foundation

/// The single Finder location Hamasen owns, and the system calls that keep it
/// in step with the set of mounted servers.
///
/// The app and the File Provider extension both change what is mounted, so
/// the domain bookkeeping lives here instead of being repeated — and
/// drifting — in each.
public enum FinderDomain {
    public static let domain = NSFileProviderDomain(
        identifier: NSFileProviderDomainIdentifier(rawValue: SharedConstants.mainDomainIdentifier),
        displayName: SharedConstants.mainDomainDisplayName
    )

    /// Registers the domain when something is mounted and removes it when
    /// nothing is, then asks Finder to re-read the server list.
    ///
    /// Removing the domain already tears the location down, so the signal is
    /// only meaningful while at least one server remains.
    ///
    /// Returns where locally modified content was preserved, if there was
    /// any: removing a domain deletes its local replica, and unmounting is a
    /// single click, so edits that never reached the server must not go with
    /// it. Nothing on the server is touched either way.
    @discardableResult
    public static func synchronize(hasMountedServers: Bool) async throws -> URL? {
        guard hasMountedServers else {
            return try await NSFileProviderManager.remove(domain, mode: .preserveDirtyUserData)
        }
        try await register()
        try await signalServerListChanged()
        return nil
    }

    /// Adds the domain unless it is already registered.
    public static func register() async throws {
        let domains = try await NSFileProviderManager.domains()
        let isRegistered = domains.contains {
            $0.identifier.rawValue == SharedConstants.mainDomainIdentifier
        }
        guard !isRegistered else { return }
        try await NSFileProviderManager.add(domain)
    }

    /// Asks the system to re-enumerate.
    ///
    /// A replicated extension only honours working-set signals; the system
    /// ignores signals for any other container and propagates working-set
    /// changes to the UI itself.
    public static func signalServerListChanged() async throws {
        try await manager().signalEnumerator(for: .workingSet)
    }

    /// The system's handle on the domain, which exists only while the domain
    /// is registered.
    public static func manager() throws -> NSFileProviderManager {
        guard let manager = NSFileProviderManager(for: domain) else {
            throw FinderDomainError.notRegistered
        }
        return manager
    }
}

public enum FinderDomainError: LocalizedError {
    case notRegistered

    public var errorDescription: String? {
        switch self {
        case .notRegistered:
            return String(localized: "Hamasen 目前沒有掛載中的位置", bundle: .module)
        }
    }
}
