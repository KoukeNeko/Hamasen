import FileProvider
import Foundation
import HamasenCore

/// Drops the local copies of servers set to "online only" once they are no
/// longer in use.
///
/// The content policy alone only biases the system: it drops a copy when the
/// server's version moves on, and reclaims space under pressure. What the user
/// actually asked for — nothing lingering — needs the provider to evict, which
/// is why this exists.
///
/// Nothing here decides whether a file is safe to drop. `evictItem` refuses an
/// item with unsynced edits, one that is open, or one the user pinned, and
/// those refusals are expected rather than exceptional.
actor OnlineOnlyEvictor {
    /// The system calls back on every change to the materialized set, which
    /// includes each write while a file is being saved. Waiting lets a burst
    /// settle, and keeps a file that is being worked on from being dropped
    /// between two saves only to be fetched again.
    private static let quietPeriod = Duration.seconds(20)

    /// At startup the manager is not usable yet — asking it anything as the
    /// extension is still being set up fails with "could not communicate with
    /// the helper application" — so the backlog pass waits for the connection
    /// to come up. Short, because the system stops an idle extension within
    /// about half a minute.
    private static let startupDelay = Duration.seconds(3)

    /// A whole mounted filesystem can hold thousands of materialized items.
    /// A pass takes a slice rather than the lot, because the extension is
    /// stopped when it goes idle and an unbounded pass would never finish.
    private static let maximumPerPass = 100
    private static let evictionSpacing = Duration.milliseconds(50)

    private let domain: NSFileProviderDomain
    private let log = HamasenLog(category: "OnlineOnly")
    private var pass: Task<Void, Never>?

    init(domain: NSFileProviderDomain) {
        self.domain = domain
    }

    /// Restarts the quiet period, so a run happens once the churn stops
    /// rather than once per change.
    ///
    /// The system stops this extension whenever it goes idle — often within
    /// half a minute — so a delayed pass is easily killed before it runs.
    /// Only the churn-driven case can afford to wait; clearing what is
    /// already on disk cannot, and asks for `afterQuietPeriod: false`.
    /// Requests a pass, coalescing with one already pending.
    ///
    /// Restarting the wait on every request would starve the pass outright:
    /// the triggers fire on enumerations, which arrive faster than the wait,
    /// so each request would cancel the last and the extension would be
    /// stopped before any of them ran.
    func scheduleEvictionPass(afterQuietPeriod: Bool = true) {
        guard pass == nil else { return }
        let delay = afterQuietPeriod ? Self.quietPeriod : Self.startupDelay
        pass = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.evictOnlineOnlyContent()
            await self?.clearPass()
        }
    }

    private func clearPass() {
        pass = nil
    }

    func cancel() {
        pass?.cancel()
        pass = nil
    }

    private func evictOnlineOnlyContent() async {
        // Every exit reports why. A pass that returns in silence is
        // indistinguishable from one that never ran, which is what made the
        // earlier failures so hard to place.
        let onlineOnlyServerIDs = onlineOnlyServers()
        guard !onlineOnlyServerIDs.isEmpty else {
            log.notice("Online-only pass: no server is set to online only")
            return
        }

        guard let manager = NSFileProviderManager(for: domain) else {
            log.notice("Online-only pass: the domain is not registered")
            return
        }
        do {
            let identifiers = try await materializedIdentifiers(from: manager)
                .filter { identifier in
                    guard let entity = ItemIdentifierMapper.entity(for: identifier),
                          let serverID = entity.serverID
                    else { return false }
                    // A server folder is the container the policy lives on;
                    // evicting it would recurse and stop at the first child
                    // that cannot be dropped, so only leaves are evicted.
                    guard case .item = entity else { return false }
                    return onlineOnlyServerIDs.contains(serverID)
                }
                guard !identifiers.isEmpty else {
                log.notice("Online-only pass: no materialized items to free")
                return
            }

            var evicted = 0
            var firstRefusal: String?
            for identifier in identifiers.prefix(Self.maximumPerPass) {
                do {
                    try await manager.evictItem(identifier: identifier)
                    evicted += 1
                } catch {
                    // In use, edited but not yet uploaded, or pinned by the
                    // user: all reasons to leave it alone until next time.
                    let refusal = error as NSError
                    firstRefusal = firstRefusal
                        ?? "\(refusal.domain) \(refusal.code) (\(identifier.rawValue))"
                }
                // Evicting without a pause competes with the sync the
                // extension is doing for the same items.
                try? await Task.sleep(for: Self.evictionSpacing)
            }
            // Reported whatever the outcome: "nothing was freed" is the case
            // worth seeing, and it is invisible if only successes are logged.
            log.notice(
                "Online-only pass: \(identifiers.count) candidates, \(evicted) freed"
                    + (firstRefusal.map { ", first refusal: \($0)" } ?? "")
            )
        } catch {
            log.error("Could not list materialized items: \(error.localizedDescription)")
        }
    }

    private func onlineOnlyServers() -> Set<UUID> {
        guard let configs = try? ConnectionRegistry.mountedConfigs() else { return [] }
        return Set(configs.filter { $0.storageMode == .onlineOnly }.map(\.id))
    }

    /// The materialized set is served as an enumerator, so it has to be
    /// drained page by page.
    private func materializedIdentifiers(
        from manager: NSFileProviderManager
    ) async throws -> [NSFileProviderItemIdentifier] {
        try await withCheckedThrowingContinuation { continuation in
            let observer = MaterializedItemCollector(continuation: continuation)
            let enumerator = manager.enumeratorForMaterializedItems()
            observer.retain(enumerator)
            enumerator.enumerateItems(for: observer, startingAt: NSFileProviderPage(Data()))
        }
    }
}

/// Collects one enumeration of the materialized set and resumes its
/// continuation exactly once, whichever way the enumeration ends.
private final class MaterializedItemCollector: NSObject, NSFileProviderEnumerationObserver, @unchecked Sendable {
    private let continuation: CheckedContinuation<[NSFileProviderItemIdentifier], Error>
    private var identifiers: [NSFileProviderItemIdentifier] = []
    private var hasResumed = false
    private var enumerator: (any NSFileProviderEnumerator)?

    init(continuation: CheckedContinuation<[NSFileProviderItemIdentifier], Error>) {
        self.continuation = continuation
    }

    /// The enumerator is only referenced by the call that started it, so it
    /// has to be held until the enumeration finishes.
    func retain(_ enumerator: any NSFileProviderEnumerator) {
        self.enumerator = enumerator
    }

    func didEnumerate(_ items: [any NSFileProviderItemProtocol]) {
        identifiers.append(contentsOf: items.map(\.itemIdentifier))
    }

    func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
        if let nextPage {
            enumerator?.enumerateItems(for: self, startingAt: nextPage)
            return
        }
        finish { continuation in continuation.resume(returning: identifiers) }
    }

    func finishEnumeratingWithError(_ error: any Error) {
        finish { continuation in continuation.resume(throwing: error) }
    }

    private func finish(
        _ resume: (CheckedContinuation<[NSFileProviderItemIdentifier], Error>) -> Void
    ) {
        guard !hasResumed else { return }
        hasResumed = true
        enumerator?.invalidate()
        enumerator = nil
        resume(continuation)
    }
}
