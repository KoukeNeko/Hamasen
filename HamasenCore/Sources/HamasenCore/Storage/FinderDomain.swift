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
    private static let log = HamasenLog(category: "domain")

    public static let domain = makeDomain(isHidden: false)

    static func makeDomain(isHidden: Bool) -> NSFileProviderDomain {
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
        domain.isHidden = isHidden
        return domain
    }

    /// Shows the domain when something is mounted and hides it when nothing
    /// is, then asks Finder to re-read the server list.
    ///
    /// Hidden, not removed: unmounting the last server and mounting one again
    /// must not remove the domain and add it back. A removal that keeps
    /// unsynced edits leaves them in the location's folder, and the domain
    /// added next takes that folder over — what was left comes back as new
    /// local items at the root, which the extension refuses and which shadow
    /// the servers' own folders. Adding a domain that already exists only
    /// updates its display name and hidden state, and a hidden one keeps its
    /// files, so nothing is left behind for a later domain to find.
    ///
    /// The signal matters when hiding too: it is how the system learns that
    /// the unmounted server's folder is gone and drops what it held on this
    /// Mac. Edits that never reached the server are not dropped with it; the
    /// system re-creates an item it finds edited instead of deleting it.
    ///
    /// Returns where unsynced edits were kept when an outdated domain had to
    /// be replaced, the one removal left here.
    @discardableResult
    public static func synchronize(hasMountedServers: Bool) async throws -> URL? {
        let store = AppSettings.sharedStore
        let registered = try await NSFileProviderManager.domains().first {
            $0.identifier == domain.identifier
        }
        let step = registrationStep(
            registered: registered,
            storedGeneration: store.integer(forKey: AppSettings.Keys.domainCapabilityGeneration),
            hasMountedServers: hasMountedServers
        )

        var preservedLocation: URL?
        switch step {
        case .leave:
            // With nothing registered there is no one to signal, and the
            // signal would throw.
            guard registered != nil else { return nil }
        case .create:
            try await addCurrentDomain()
            log.notice("Added the Finder location")
        case .setHidden(let isHidden):
            // The generation is not touched: the domain keeps the
            // capabilities it was created with.
            try await NSFileProviderManager.add(makeDomain(isHidden: isHidden))
            log.notice(isHidden ? "Hid the Finder location: nothing is mounted" : "Showed the Finder location")
        case .replace:
            // Removing drops the replica: cached copies are downloaded again
            // the next time they are opened, a cost paid once and only by
            // someone whose domain predates a capability. Edits that have
            // not reached the server are kept, possibly in the location's
            // own folder, which the add that follows then takes over (see
            // above); resetting the location is the way out of that.
            preservedLocation = try await NSFileProviderManager.remove(domain, mode: .preserveDirtyUserData)
            if let preservedLocation {
                // The one record of where unsynced edits went, written
                // before the add has a chance to fail.
                log.notice("Removed the outdated Finder location; unsynced edits were kept at \(preservedLocation.path)")
            }
            try await addCurrentDomain()
            log.notice("Replaced the Finder location")
        }
        try await signalWorkingSet()
        return preservedLocation
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
    ///
    /// What this system can declare, not what the code knows about: search
    /// needs macOS 26, and a domain added before that records generation 1,
    /// so it is replaced — and gains search — once the Mac is upgraded.
    private static var capabilityGeneration: Int {
        if #available(macOS 26, *) { return 2 }
        return 1
    }

    /// Whether a registered domain predates what `domain` now declares.
    ///
    /// Wrong in either direction is expensive: never replacing leaves a
    /// capability permanently unreachable, and replacing every launch throws
    /// the replica away every launch.
    static func needsReplacing(storedGeneration: Int) -> Bool {
        storedGeneration < capabilityGeneration
    }

    /// What `synchronize` does to the registration.
    enum RegistrationStep: Equatable {
        /// Already as it should be, or nothing registered to hide.
        case leave
        /// Adds the domain where none is registered.
        case create
        /// Shows or hides the registered domain and changes nothing else.
        case setHidden(Bool)
        /// Removes a domain that predates what `domain` declares, and adds
        /// it again.
        case replace
    }

    /// Decides the step from what is registered now.
    ///
    /// Only `replace` removes anything, and it is never the answer while
    /// nothing is mounted: an outdated domain is just as well replaced at
    /// the next mount, and that is when the capability is first wanted.
    static func registrationStep(
        registered: NSFileProviderDomain?,
        storedGeneration: Int,
        hasMountedServers: Bool
    ) -> RegistrationStep {
        guard let registered else {
            // A domain exists for something to show; one is not created
            // just to be hidden.
            return hasMountedServers ? .create : .leave
        }
        guard hasMountedServers else {
            return registered.isHidden ? .leave : .setHidden(true)
        }
        if needsReplacing(storedGeneration: storedGeneration) {
            return .replace
        }
        return registered.isHidden ? .setHidden(false) : .leave
    }

    /// Adds `domain` as declared now, and records that what is registered
    /// carries every capability this system can declare.
    private static func addCurrentDomain() async throws {
        try await NSFileProviderManager.add(domain)
        AppSettings.sharedStore.set(capabilityGeneration, forKey: AppSettings.Keys.domainCapabilityGeneration)
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

    /// Empties the Finder location and builds it again, for a location the
    /// system can no longer bring into line with the servers.
    ///
    /// A removal that keeps edits that never reached a server — replacing an
    /// outdated domain, or unmounting the last server in builds before the
    /// domain was hidden instead — can leave them in the location's folder.
    /// The domain added next takes that folder over and treats what is in it
    /// as new local items, which shadow the servers' own. This keeps nothing:
    /// copies on this Mac go, and so do unsynced edits. The servers are not
    /// touched.
    ///
    /// With nothing mounted the domain is only removed; the next mount adds
    /// it as new.
    public static func reset(hasMountedServers: Bool) async throws {
        let registered = try await NSFileProviderManager.domains()
        if registered.contains(where: { $0.identifier == domain.identifier }) {
            _ = try await NSFileProviderManager.remove(domain, mode: .removeAll)
            log.notice("Reset the Finder location: removed it with everything in it")
        }
        guard hasMountedServers else { return }
        try await addCurrentDomain()
        log.notice("Added the Finder location")
        try await signalWorkingSet()
    }

    /// Lifts a pause earlier versions put on the whole domain by answering a
    /// read that could not reach one server, or whose password was refused,
    /// with `.serverUnreachable` or `.notAuthenticated`. Reads no longer
    /// pause anything — every server shares this domain — but a pause
    /// already in place lasts until it is reported resolved. A write still
    /// waiting on such a server reports it again, and pauses again.
    public static func releaseDomainWidePauses() async throws {
        let manager = try manager()
        try await manager.signalErrorResolved(NSFileProviderError(.serverUnreachable))
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
