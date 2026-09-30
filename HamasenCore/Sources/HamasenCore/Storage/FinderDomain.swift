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
    public static let domain: NSFileProviderDomain = {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(
                rawValue: SharedConstants.mainDomainIdentifier),
            displayName: SharedConstants.mainDomainDisplayName
        )
        // Off by default, and the extension's NSFileProviderSearching
        // conformance is never consulted without it.
        if #available(macOS 26, *) {
            domain.supportsStringSearchRequest = true
        }
        return domain
    }()

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
        try await signalWorkingSet()
        return nil
    }

    /// Bumped whenever a property of `domain` changes what the system will
    /// ask the extension for.
    ///
    /// Adding a domain that already exists updates its display name and
    /// hidden state — the header says so, and lists only those two. Every
    /// other capability is fixed when the domain is created, so a domain
    /// registered before a capability existed can never gain it. This is what
    /// tells the two apart.
    ///
    /// 1: the original domain.
    /// 2: search, so Spotlight can ask the extension for results (macOS 26+).
    private static let capabilityGeneration = 2

    /// Whether a registered domain predates what `domain` now declares.
    ///
    /// Wrong in either direction is expensive: never replacing leaves a
    /// capability permanently unreachable, and replacing every launch throws
    /// the replica away every launch.
    static func needsReplacing(storedGeneration: Int) -> Bool {
        storedGeneration < capabilityGeneration
    }

    /// Adds the domain, replacing one created before the capabilities it
    /// declares now.
    ///
    /// Replacing means removing, which drops the replica: cached copies are
    /// downloaded again the next time they are opened. Edits that have not
    /// reached the server are kept, which is what `.preserveDirtyUserData`
    /// is for. That cost is paid once, and only by someone whose domain
    /// predates a capability.
    public static func register() async throws {
        let store = AppSettings.sharedStore
        let domains = try await NSFileProviderManager.domains()
        let isRegistered = domains.contains {
            $0.identifier.rawValue == SharedConstants.mainDomainIdentifier
        }

        if isRegistered {
            let generation = store.integer(forKey: AppSettings.Keys.domainCapabilityGeneration)
            guard needsReplacing(storedGeneration: generation) else { return }
            _ = try await NSFileProviderManager.remove(domain, mode: .preserveDirtyUserData)
        }
        try await NSFileProviderManager.add(domain)
        store.set(capabilityGeneration, forKey: AppSettings.Keys.domainCapabilityGeneration)
    }

    /// Asks the system to re-enumerate.
    ///
    /// A replicated extension only honours working-set signals; the system
    /// ignores signals for any other container and propagates working-set
    /// changes to the UI itself.
    public static func signalWorkingSet() async throws {
        try await manager().signalEnumerator(for: .workingSet)
    }

    /// Tells the system that whatever made the extension answer "not
    /// authenticated" may be fixed, then asks it to look again.
    ///
    /// That answer — a refused password, a host key that changed — pauses
    /// the whole domain until the error is reported resolved; a signal alone
    /// does not lift it. Only the app can fix those causes, so the app says
    /// so after the person changes credentials or clears a host key. If the
    /// cause is still there, the next operation reports it again.
    public static func signalAuthenticationResolved() async throws {
        let manager = try manager()
        try await manager.signalErrorResolved(NSFileProviderError(.notAuthenticated))
        try await manager.signalEnumerator(for: .workingSet)
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
