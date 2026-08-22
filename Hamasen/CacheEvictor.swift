import FileProvider
import Foundation
import HamasenCore
import UniformTypeIdentifiers

/// Keeps each server's cached content within what the user allowed.
///
/// This runs in the app rather than in the File Provider extension. The
/// extension cannot drive it: asking `NSFileProviderManager` for the
/// materialized set from inside the extension usually fails to reach the
/// helper, and on the run where it did succeed every `evictItem` returned
/// EAGAIN — the extension was calling the system back while that same system
/// was asking it to serve the domain. The app is an ordinary client of the
/// manager, which is the relationship these calls expect.
///
/// Nothing here decides whether a file is safe to drop: `evictItem` refuses an
/// item that has unsynced edits, is open, or was pinned by the user, and those
/// refusals are expected rather than exceptional.
actor CacheEvictor {
    /// A whole mounted filesystem can hold thousands of materialized items.
    /// A pass takes a slice, and the next pass continues, so one sweep cannot
    /// occupy the app indefinitely.
    private static let maximumPerPass = 200

    /// Evicting back to back competes with the sync the extension is doing
    /// for the same items.
    private static let evictionSpacing = Duration.milliseconds(20)

    private let log = HamasenLog(category: "OnlineOnly")
    private var isRunning = false

    /// Frees whatever the given servers are holding beyond their allowance.
    ///
    /// - Parameter servers: the mounted servers. Passed in because the app
    ///   already knows them; reading them again here could disagree with what
    ///   the user sees.
    /// What one pass found that the user may need to act on.
    struct Outcome {
        /// The system refused something as non-evictable, which means content
        /// predating the evicting capability is still on disk and only a
        /// remount can clear it.
        var needsRemount = false
        /// Servers whose pinned content alone exceeds their allowance. No
        /// sweep can bring these under it.
        var heldOverByPins: [UUID: PinnedOverage] = [:]
        /// What each server is holding, for the settings to show.
        var usage: [UUID: CacheUsage] = [:]
    }

    /// Measures without dropping anything, for when the user is looking at a
    /// server rather than when the allowance needs enforcing.
    func measureUsage(for servers: [ServerConfig]) async -> [UUID: CacheUsage] {
        guard let manager = try? FinderDomain.manager(),
              let materialized = try? await materializedItems(from: manager)
        else { return [:] }
        let pinned = (try? PinnedItemsStore().loadPinnedIdentifiers()) ?? []
        let items = await measured(cachedItems(from: materialized), for: servers, using: manager)
        return CacheEvictionPlan.usage(of: items, pinned: pinned)
    }

    /// Fills in what each file actually occupies.
    ///
    /// The enumerated items carry no `documentSize` — the system reports zero
    /// for every one of them — so the sizes come from the files themselves.
    /// Allocated size rather than logical size, which is the same distinction
    /// the cache cares about: a dataless file occupies nothing.
    private func measured(
        _ items: [CachedItem],
        for servers: [ServerConfig],
        using manager: NSFileProviderManager
    ) async -> [CachedItem] {
        guard let root = try? await manager.getUserVisibleURL(for: .rootContainer) else { return items }
        // One claim for the whole walk: the app has no standing access to
        // ~/Library/CloudStorage.
        let hasAccess = root.startAccessingSecurityScopedResource()
        defer { if hasAccess { root.stopAccessingSecurityScopedResource() } }

        let folderNames = Dictionary(
            servers.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }
        )
        return items.map { item in
            guard let folder = folderNames[item.serverID],
                  case .item(_, let path)? = ItemIdentifierMapper.entity(for: .init(item.identifier))
            else { return item }

            // The identifier's path is the location inside the server folder,
            // which is named after the server.
            let location = path.split(separator: "/").reduce(root.appending(path: folder)) {
                $0.appending(path: String($1))
            }
            let allocated = (try? location.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                .totalFileAllocatedSize
            return CachedItem(
                identifier: item.identifier,
                serverID: item.serverID,
                byteCount: Int64(allocated ?? 0),
                modifiedAt: item.modifiedAt
            )
        }
    }

    @discardableResult
    func evictContent(for servers: [ServerConfig]) async -> Outcome {
        let policies = Dictionary(
            servers.map { ($0.id, $0.cachePolicy) }, uniquingKeysWith: { first, _ in first }
        )
        let isManaged = policies.values.contains { $0 != .unlimited }
        guard isManaged, !isRunning else { return Outcome() }
        isRunning = true
        defer { isRunning = false }

        let manager: NSFileProviderManager
        do {
            manager = try FinderDomain.manager()
        } catch {
            return Outcome()
        }

        do {
            let cached = await measured(
                cachedItems(from: try await materializedItems(from: manager)),
                for: servers,
                using: manager
            )
            // What the user pinned is exempt, whatever the allowance says.
            let pinned = (try? PinnedItemsStore().loadPinnedIdentifiers()) ?? []
            var outcome = Outcome(
                heldOverByPins: CacheEvictionPlan.serversHeldOverAllowanceByPins(
                    items: cached, policies: policies, pinned: pinned
                ),
                usage: CacheEvictionPlan.usage(of: cached, pinned: pinned)
            )
            let candidates = CacheEvictionPlan.itemsToEvict(
                from: cached, policies: policies, pinned: pinned, limit: Self.maximumPerPass
            ).map(NSFileProviderItemIdentifier.init(rawValue:))
            guard !candidates.isEmpty else {
                // Reported rather than returned in silence: "nothing to free"
                // and "the filter matched nothing" look identical from
                // outside, and telling them apart is the whole diagnosis.
                log.notice(
                    "Cache pass: nothing to free"
                        + " (\(cached.count) cached files, \(Self.describe(outcome.usage)))"
                )
                return outcome
            }

            var evicted = 0
            var firstRefusal: String?
            for identifier in candidates {
                do {
                    try await manager.evictItem(identifier: identifier)
                    evicted += 1
                } catch {
                    let refusal = error as NSError
                    firstRefusal = firstRefusal ?? "\(refusal.domain) \(refusal.code)"
                    // The capability that permits eviction reaches the system
                    // with the item, so content stored before it was declared
                    // can never be freed in place.
                    outcome.needsRemount = outcome.needsRemount
                        || (refusal.domain == NSFileProviderError.errorDomain
                            && refusal.code == NSFileProviderError.nonEvictable.rawValue)
                }
                try? await Task.sleep(for: Self.evictionSpacing)
            }
            log.notice(
                "Cache pass: \(candidates.count) candidates, \(evicted) freed"
                    + ", \(Self.describe(outcome.usage))"
                    + (firstRefusal.map { ", first refusal: \($0)" } ?? "")
            )
            return outcome
        } catch {
            log.error("Could not list materialized items: \(error.localizedDescription)")
            return Outcome()
        }
    }

    private static func describe(_ usage: [UUID: CacheUsage]) -> String {
        guard !usage.isEmpty else { return "no usage" }
        return usage
            .map { "\($0.key.uuidString.prefix(8)) \($0.value.totalBytes) bytes" }
            .sorted()
            .joined(separator: ", ")
    }

    /// Files only. Evicting a directory recurses and stops at the first child
    /// it cannot drop, so a tree of folders fails as a block while its files
    /// could have been freed one by one — and a folder reports no size worth
    /// counting either.
    private func cachedItems(from materialized: [any NSFileProviderItemProtocol]) -> [CachedItem] {
        materialized.compactMap { item in
            guard item.contentType != .folder,
                  case .item(let serverID, _)? = ItemIdentifierMapper.entity(for: item.itemIdentifier)
            else { return nil }
            return CachedItem(
                identifier: item.itemIdentifier.rawValue,
                serverID: serverID,
                byteCount: item.documentSize??.int64Value ?? 0,
                modifiedAt: item.contentModificationDate ?? nil
            )
        }
    }

    /// The materialized set is served as an enumerator, so it has to be
    /// drained page by page.
    private func materializedItems(
        from manager: NSFileProviderManager
    ) async throws -> [any NSFileProviderItemProtocol] {
        try await withCheckedThrowingContinuation { continuation in
            let collector = MaterializedItemCollector(continuation: continuation)
            collector.start(manager.enumeratorForMaterializedItems())
        }
    }
}

/// Collects one enumeration of the materialized set and resumes its
/// continuation exactly once, whichever way the enumeration ends.
private nonisolated final class MaterializedItemCollector: NSObject, NSFileProviderEnumerationObserver, @unchecked Sendable {
    private let continuation: CheckedContinuation<[any NSFileProviderItemProtocol], Error>
    private var items: [any NSFileProviderItemProtocol] = []
    private var hasResumed = false
    /// Held because the enumerator is otherwise only referenced by the call
    /// that started it, and it has to outlive that call.
    private var enumerator: (any NSFileProviderEnumerator)?

    /// Nonisolated because the enumerator drives this from whatever queue it
    /// runs on; the protocol it conforms to is declared on the main actor,
    /// which would otherwise put every callback there.
    init(continuation: CheckedContinuation<[any NSFileProviderItemProtocol], Error>) {
        self.continuation = continuation
    }

    func start(_ enumerator: any NSFileProviderEnumerator) {
        self.enumerator = enumerator
        enumerator.enumerateItems(for: self, startingAt: NSFileProviderPage(Data()))
    }

    func didEnumerate(_ items: [any NSFileProviderItemProtocol]) {
        self.items.append(contentsOf: items)
    }

    func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
        if let nextPage {
            enumerator?.enumerateItems(for: self, startingAt: nextPage)
            return
        }
        finish { $0.resume(returning: items) }
    }

    func finishEnumeratingWithError(_ error: any Error) {
        finish { $0.resume(throwing: error) }
    }

    private func finish(
        _ resume: (CheckedContinuation<[any NSFileProviderItemProtocol], Error>) -> Void
    ) {
        guard !hasResumed else { return }
        hasResumed = true
        enumerator?.invalidate()
        enumerator = nil
        resume(continuation)
    }
}
