import FileProvider
import Foundation

/// The single Finder location Hamasen owns, and the system calls that keep it
/// in step with the set of mounted servers.
///
/// The app and the UI extension both change what is mounted, so the domain
/// bookkeeping lives here instead of being repeated — and drifting — in each.
public enum FinderDomain {
    private static let log = HamasenLog(category: "FinderDomain")
    private static let locationPublishMaximumAttempts = 8
    private static let locationPublishInitialDelayNanoseconds: UInt64 = 250_000_000
    private static let locationPublishMaximumDelayNanoseconds: UInt64 = 2_000_000_000

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
            // Stop FinderSync from claiming a CloudStorage path that is no
            // longer owned by an active domain. Clear this before removal so
            // a failed system call cannot leave a stale context-menu scope.
            clearPublishedUserVisibleLocation()
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
        guard let manager = NSFileProviderManager(for: domain) else {
            throw FinderDomainError.notRegistered
        }
        try await manager.signalEnumerator(for: .workingSet)
    }

    /// Stores the mount's on-disk location in the shared defaults, for the
    /// FinderSync extension to read.
    ///
    /// Only the app may call this: resolving the location asks fileproviderd
    /// over XPC, and from the FinderSync extension's sandbox that call never
    /// completes — it neither answers nor fails, which is why the extension
    /// reads the published value instead of asking the system itself.
    public static func publishUserVisibleLocation() async {
        do {
            let location = try await resolveUserVisibleLocationWithRetry(
                maximumAttempts: locationPublishMaximumAttempts,
                initialDelayNanoseconds: locationPublishInitialDelayNanoseconds,
                maximumDelayNanoseconds: locationPublishMaximumDelayNanoseconds,
                resolve: {
                    guard let manager = NSFileProviderManager(for: domain) else {
                        throw FinderDomainError.notRegistered
                    }
                    return try await manager.getUserVisibleURL(for: .rootContainer)
                },
                sleep: { try await Task.sleep(nanoseconds: $0) }
            )
            AppSettings.sharedStore.set(location.path, forKey: AppSettings.Keys.mountRootPath)
            log.debug("Published Finder mount location at \(location.path)")
        } catch is CancellationError {
            log.debug("Publishing Finder mount location was cancelled")
        } catch {
            log.error("Publishing Finder mount location failed: \(error.localizedDescription)")
        }
    }

    /// Resolves a just-registered File Provider location without assuming the
    /// manager and its user-visible URL become ready atomically. Kept internal
    /// so unit tests can exercise the race without talking to fileproviderd.
    static func resolveUserVisibleLocationWithRetry(
        maximumAttempts: Int,
        initialDelayNanoseconds: UInt64,
        maximumDelayNanoseconds: UInt64,
        resolve: () async throws -> URL,
        sleep: (UInt64) async throws -> Void
    ) async throws -> URL {
        precondition(maximumAttempts > 0)

        var delay = initialDelayNanoseconds
        var lastError: Error?

        for attempt in 1...maximumAttempts {
            do {
                return try await resolve()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                guard attempt < maximumAttempts else { break }
                try await sleep(delay)
                delay = min(delay.multipliedReportingOverflow(by: 2).partialValue, maximumDelayNanoseconds)
            }
        }

        throw FinderDomainError.userVisibleLocationUnavailable(
            attempts: maximumAttempts,
            lastError: lastError?.localizedDescription ?? "unknown error"
        )
    }

    /// The location the app last published, or nil before its first launch
    /// with a mounted server.
    public static func publishedUserVisibleLocation() -> URL? {
        guard let path = AppSettings.sharedStore.string(forKey: AppSettings.Keys.mountRootPath)
        else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Removes the shared FinderSync scope when the File Provider domain is
    /// no longer mounted. The injectable store keeps this behavior testable
    /// without requiring an App Group entitlement in package tests.
    static func clearPublishedUserVisibleLocation(
        from store: UserDefaults = AppSettings.sharedStore
    ) {
        store.removeObject(forKey: AppSettings.Keys.mountRootPath)
    }
}

public enum FinderDomainError: LocalizedError {
    case notRegistered
    case userVisibleLocationUnavailable(attempts: Int, lastError: String)

    public var errorDescription: String? {
        switch self {
        case .notRegistered:
            return "Hamasen 目前沒有掛載中的位置"
        case .userVisibleLocationUnavailable(let attempts, let lastError):
            return "嘗試 \(attempts) 次後仍無法取得 Finder 掛載位置：\(lastError)"
        }
    }
}
