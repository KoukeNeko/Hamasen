import FileProvider
import Foundation
import HamasenCore
import UniformTypeIdentifiers

/// Drops the local copies of servers set to "online only".
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
actor OnlineOnlyEvictor {
    /// A whole mounted filesystem can hold thousands of materialized items.
    /// A pass takes a slice, and the next pass continues, so one sweep cannot
    /// occupy the app indefinitely.
    private static let maximumPerPass = 200

    /// Evicting back to back competes with the sync the extension is doing
    /// for the same items.
    private static let evictionSpacing = Duration.milliseconds(20)

    private let log = HamasenLog(category: "OnlineOnly")
    private var isRunning = false

    /// Frees what the given servers are holding on this Mac.
    ///
    /// - Parameter onlineOnlyServerIDs: the mounted servers set to online
    ///   only. Passed in because the app already knows the list; reading it
    ///   again here could disagree with what the user sees.
    func evictContent(of onlineOnlyServerIDs: Set<UUID>) async {
        guard !onlineOnlyServerIDs.isEmpty, !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        let manager: NSFileProviderManager
        do {
            manager = try FinderDomain.manager()
        } catch {
            return
        }

        do {
            let materialized = try await materializedItems(from: manager)
            let candidates = materialized
                .filter { item in
                    // Files only. Evicting a directory recurses and stops at
                    // the first child it cannot drop, so a tree of folders
                    // fails as a block while its files could have been freed
                    // one by one.
                    guard item.contentType != .folder,
                          case .item(let serverID, _)? = ItemIdentifierMapper.entity(for: item.itemIdentifier)
                    else { return false }
                    return onlineOnlyServerIDs.contains(serverID)
                }
                .prefix(Self.maximumPerPass)
                .map(\.itemIdentifier)
            guard !candidates.isEmpty else {
                // Reported rather than returned in silence: "nothing to free"
                // and "the filter matched nothing" look identical from
                // outside, and telling them apart is the whole diagnosis.
                let folders = materialized.filter { $0.contentType == .folder }.count
                log.notice(
                    "Online-only pass: nothing to free"
                        + " (\(materialized.count) materialized, \(folders) of them folders)"
                )
                return
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
                }
                try? await Task.sleep(for: Self.evictionSpacing)
            }
            log.notice(
                "Online-only pass: \(candidates.count) candidates, \(evicted) freed"
                    + (firstRefusal.map { ", first refusal: \($0)" } ?? "")
            )
        } catch {
            log.error("Could not list materialized items: \(error.localizedDescription)")
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
private final class MaterializedItemCollector: NSObject, NSFileProviderEnumerationObserver, @unchecked Sendable {
    private let continuation: CheckedContinuation<[any NSFileProviderItemProtocol], Error>
    private var items: [any NSFileProviderItemProtocol] = []
    private var hasResumed = false
    /// Held because the enumerator is otherwise only referenced by the call
    /// that started it, and it has to outlive that call.
    private var enumerator: (any NSFileProviderEnumerator)?

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
