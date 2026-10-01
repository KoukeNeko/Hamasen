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
import HamasenCore

/// Hands the system every server's tree, one directory per page.
///
/// The working set is what the replica holds and what Spotlight indexes.
/// Until now it was the server folders alone, so Spotlight knew only what
/// Finder had happened to open. This walks the rest in the background, at the
/// system's pace: each page lists one directory, queues its subdirectories,
/// and names the next page, and the system decides when to ask for it.
///
/// The first page is the server list, exactly as before. A walk that fails
/// on a server, or is told not to index it, leaves Finder browsing untouched —
/// the directory enumerators serve that, and this only adds to the replica.
final class WorkingSetEnumerator: NSObject, NSFileProviderEnumerator {
    private static let log = HamasenLog(category: "workingset")

    private let registry: ConnectionRegistry
    private let serverList = ServerListEnumerator()

    init(registry: ConnectionRegistry) {
        self.registry = registry
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        // The system's own first-page markers are not ours to interpret, and
        // the header says only what they "typically" are. A page is a
        // continuation when it decodes as one of our tokens, and a first page
        // otherwise — which is also the safe reading of anything unexpected.
        let token = WorkingSetWalk.decode(page.rawValue)

        let configs: [ServerConfig]
        do {
            configs = try ConnectionRegistry.mountedConfigs()
        } catch {
            observer.finishEnumeratingWithError(FileProviderErrorMapper.map(error))
            return
        }

        guard let store = try? WorkingSetWalkStore() else {
            // No app group means no walk, not no working set: the server
            // folders still go out so Finder keeps working.
            observer.didEnumerate(configs.map(ServerFolderItem.init))
            observer.finishEnumerating(upTo: nil)
            return
        }

        let indexable = configs.filter(\.indexesInBackground).map(\.id)
        var walk = store.walk(for: token, serverIDs: indexable, limits: AppSettings.indexingLimits())
        if token == nil {
            Self.log.notice(
                "Walk started over \(indexable.count) of \(configs.count) servers: "
                + "depth \(walk.limits.maximumDepth), per server \(walk.limits.maximumDirectories) directories, "
                + "\(walk.limits.maximumItems) items")
        } else {
            Self.log.debug("Walk page: queued=\(walk.queue.count) listed=\(walk.directoriesListed)")
        }

        if token == nil {
            observer.didEnumerate(configs.map(ServerFolderItem.init))
        }

        guard walk.current != nil else {
            // Nothing to list: every server opted out, which is still a walk
            // that ran, or it would be due again on every signal — or what is
            // left waits for an unreachable server, and a later change batch
            // resumes it.
            if walk.isFinished { walk.markCompleted() }
            try? store.save(walk)
            observer.finishEnumerating(upTo: nil)
            return
        }

        let registry = registry
        Task {
            if let listed = await Self.listCurrent(of: &walk, registry: registry) {
                observer.didEnumerate(listed.items.map { RemoteFileItem(serverID: listed.serverID, remoteItem: $0) })
            }

            if walk.isFinished {
                walk.markCompleted()
                Self.log.notice("Walk finished after \(walk.directoriesListed) directories")
            }

            do {
                try store.save(walk)
            } catch {
                // Without the file the next page cannot resume. Finishing
                // here keeps what was listed; the next enumeration starts a
                // new walk.
                Self.log.error("Could not save the working-set walk: \(error.localizedDescription)")
                observer.finishEnumerating(upTo: nil)
                return
            }

            if walk.isFinished || walk.isWaiting() {
                observer.finishEnumerating(upTo: nil)
            } else {
                observer.finishEnumerating(upTo: NSFileProviderPage(WorkingSetWalk.encode(walk.token)))
            }
        }
    }

    /// The one channel a replicated extension has for changes: the system
    /// asks here when signalled, and propagates what it hears to whatever
    /// Finder is showing. Three things come through it — the server list's
    /// own diff, the directories somebody queued for a refresh, and, when a
    /// walk is due, the walk itself, one directory per call.
    ///
    /// The walk used to be started by answering with an expired anchor, which
    /// makes the system drop its working set and import it again — and while
    /// a domain is importing, background downloads stall. Reported as changes
    /// it costs nothing but the listings: each call lists a directory,
    /// reports what is in it, and ends with `moreComing`, which the header
    /// says makes the system ask again with the anchor just returned. The
    /// anchor carries which walk and which step, the walk's queue being in
    /// the app group.
    ///
    /// Not in the same call as a server change or a refresh, though:
    /// enumerating the working set adds to it and removes nothing, so a
    /// removed server reported that way would stay in Finder, and a queued
    /// refresh would wait for the next signal. Those go out first, and ask
    /// to be called again for the walk.
    ///
    /// A refresh leaves the queue once it was reported. One that failed stays
    /// for the next signal, and does not hold the walk back: that would let
    /// a server that is down stop every other server from being indexed.
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let changes: ServerListEnumerator.PendingChanges
        do {
            changes = try ServerListEnumerator.pendingChanges(since: anchor)
        } catch {
            observer.finishEnumeratingWithError(FileProviderErrorMapper.map(error))
            return
        }

        let queue = try? DirectoryRefreshQueue()
        let queued: Set<DirectoryRefreshQueue.Entry>
        do {
            queued = try queue?.pending() ?? []
        } catch {
            Self.log.error("Could not read the refresh queue: \(error.localizedDescription)")
            queued = []
        }

        let walkStore = try? WorkingSetWalkStore()
        let indexable = changes.configs.filter(\.indexesInBackground).map(\.id)
        let limits = AppSettings.indexingLimits()
        let nextWalk = walkStore?.walkForChangeBatch(
            after: changes.previousWalk, serverIDs: indexable, limits: limits)
        Self.log.notice(
            "Working set changes requested: serverChanges=\(!changes.diff.isEmpty) "
            + "refreshes=\(queued.count) walkDue=\(nextWalk != nil)")

        let registry = registry
        let serverList = serverList
        Task {
            var reported: Set<DirectoryRefreshQueue.Entry> = []
            for refresh in queued.sorted(by: { $0.path < $1.path }) {
                do {
                    try await DirectoryRefresh.report(
                        serverID: refresh.serverID, directoryPath: refresh.path, registry: registry, to: observer)
                    reported.insert(refresh)
                    await registry.reportReachable(refresh.serverID)
                } catch {
                    // Stays queued: the change is not lost with the server
                    // being down, and a server that is down must not hold up
                    // the server list. The signal that brought it here is
                    // spent, though, so the probe that notices the server
                    // coming back is what makes the next one.
                    Self.log.notice("Could not refresh \(refresh.path) on \(refresh.serverID): \(error.localizedDescription)")
                    if FileProviderErrorMapper.isConnectionFailure(error) {
                        await registry.reportUnreachable(refresh.serverID)
                    }
                }
            }
            var clearedRefreshes = false
            if !reported.isEmpty {
                do {
                    try queue?.remove(reported)
                    clearedRefreshes = true
                } catch {
                    // Reported again next time, which is harmless — but not
                    // a reason to ask for another call, which would find the
                    // same entries and never end.
                    Self.log.error("Could not take reported refreshes off the queue: \(error.localizedDescription)")
                }
            }

            // A batch that reported anything ends on a new anchor, as the
            // header expects; one that repeats the last could be read as
            // nothing having changed, with the queue already cleared.
            let batch = !reported.isEmpty || !changes.diff.isEmpty
                ? ServerListEnumerator.newBatch() : changes.previousBatch
            guard var walk = nextWalk, let walkStore else {
                serverList.report(changes, to: observer, walk: changes.previousWalk, batch: batch)
                return
            }
            if !changes.diff.isEmpty || clearedRefreshes {
                serverList.report(
                    changes, to: observer, walk: changes.previousWalk, batch: batch, moreComing: true)
                return
            }

            await Self.step(&walk, registry: registry, to: observer)
            do {
                try walkStore.save(walk)
            } catch {
                // Without the file the next call cannot resume. Ending here
                // keeps what was listed; the walk is due again.
                Self.log.error("Could not save the working-set walk: \(error.localizedDescription)")
                serverList.report(
                    changes, to: observer, walk: changes.previousWalk, batch: ServerListEnumerator.newBatch())
                return
            }
            // A walk waiting on an unreachable server pauses here; the probe
            // that sees it back signals, and the next batch resumes it.
            serverList.report(
                changes, to: observer, walk: walk.token, batch: ServerListEnumerator.newBatch(),
                moreComing: !walk.isFinished && !walk.isWaiting())
        }
    }

    /// Reports the walk's current directory as part of a change batch.
    ///
    /// Names gone since the last opening or the last walk are reported
    /// deleted; the notification baseline stays where the last opening put
    /// it (see `RemoteDirectoryRecord.removedNames`).
    private static func step(
        _ walk: inout WorkingSetWalk, registry: ConnectionRegistry, to observer: NSFileProviderChangeObserver
    ) async {
        if let listed = await listCurrent(of: &walk, registry: registry) {
            observer.didUpdate(listed.items.map { RemoteFileItem(serverID: listed.serverID, remoteItem: $0) })
            let removed = DirectoryRefresh.identifiers(
                ofRemoved: RemoteDirectoryRecord.removedNames(
                    from: listed.allItems, serverID: listed.serverID, directoryPath: listed.path),
                serverID: listed.serverID, directoryPath: listed.path)
            if !removed.isEmpty {
                observer.didDeleteItems(withIdentifiers: removed)
            }
        }
        if walk.isFinished {
            walk.markCompleted()
            Self.log.notice("Walk finished after \(walk.directoriesListed) directories")
        }
    }

    /// One directory the walk listed: what to report, and the whole listing
    /// for telling what went.
    private struct Listed {
        let serverID: UUID
        let path: String
        let items: [RemoteItem]
        let allItems: [RemoteItem]
    }

    /// Lists the walk's current directory and moves the walk on, for both
    /// the first import's pages and the change batches.
    ///
    /// - Only as many items are reported as the server's budget has left:
    ///   one folder with hundreds of thousands of entries would otherwise
    ///   create every placeholder before the budget was even checked.
    /// - A link is reported but not walked into, whatever it points at — a
    ///   link to an ancestor would otherwise expand without end.
    /// - A server that cannot be reached postpones the directory rather
    ///   than dropping its branch; one it refuses is skipped.
    private static func listCurrent(
        of walk: inout WorkingSetWalk, registry: ConnectionRegistry
    ) async -> Listed? {
        guard let pending = walk.current else { return nil }
        do {
            let service = try await registry.service(for: pending.serverID)
            let items = try await service.listDirectory(at: pending.path)
            Self.log.debug("Walked \(pending.path) on \(pending.serverID): \(items.count) items")
            let reported = Array(items.prefix(walk.remainingItems(for: pending.serverID)))
            walk.advance(
                itemCount: items.count,
                subdirectories: reported.filter { $0.isDirectory && !$0.isResolvedLink }.map(\.name))
            return Listed(serverID: pending.serverID, path: pending.path, items: reported, allItems: items)
        } catch {
            if FileProviderErrorMapper.isConnectionFailure(error) {
                Self.log.notice("Postponing \(pending.path) on \(pending.serverID): \(error.localizedDescription)")
                await registry.reportUnreachable(pending.serverID)
                walk.postponeCurrent()
            } else {
                // One directory the account cannot read must not end the walk
                // for every other one.
                Self.log.notice("Skipping \(pending.path) on \(pending.serverID): \(error.localizedDescription)")
                walk.skipCurrent()
            }
            return nil
        }
    }

    /// Carries the walk under way, as the anchors `enumerateChanges` returns
    /// do. Without it the next change batch could not resume the walk, and
    /// since a walk started less than a day ago is not due, the rest of the
    /// tree would wait a day.
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let walk = (try? WorkingSetWalkStore())?.load()
        let ongoing = walk.flatMap { $0.completedAt == nil && !$0.isFinished ? $0.token : nil }
        serverList.currentSyncAnchor(walk: ongoing, completionHandler: completionHandler)
    }
}
