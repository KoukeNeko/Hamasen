import FileProvider
import Foundation

/// The single Finder location Hamasen owns, and the system calls that keep it
/// in step with the set of mounted servers.
///
/// The app and the UI extension both change what is mounted, so the domain
/// bookkeeping lives here instead of being repeated — and drifting — in each.
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
    public static func synchronize(hasMountedServers: Bool) async throws {
        guard hasMountedServers else {
            try await NSFileProviderManager.remove(domain)
            return
        }
        try await register()
        try await signalServerListChanged()
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
        guard let manager = NSFileProviderManager(for: domain) else {
            throw FinderDomainError.notRegistered
        }
        try await manager.signalEnumerator(for: .workingSet)
    }
}

public enum FinderDomainError: LocalizedError {
    case notRegistered

    public var errorDescription: String? {
        switch self {
        case .notRegistered:
            return "Hamasen 目前沒有掛載中的位置"
        }
    }
}
