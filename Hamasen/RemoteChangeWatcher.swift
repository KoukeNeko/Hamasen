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
import Observation
import UniformTypeIdentifiers
import UserNotifications

/// Notices what changed on a server and says so.
///
/// Nothing Hamasen speaks has a change feed, so noticing means asking, and
/// asking every directory would cost a request per directory per round. What
/// is re-checked instead is the materialized set — the folders somebody has
/// opened — which is the same choice Nextcloud's client makes and for the
/// same reason: those are the folders whose contents anyone is in a position
/// to notice.
///
/// In the app rather than the extension because the extension is started and
/// stopped by the system and has nowhere to keep a timer, and because a
/// notification comes from an app.
@MainActor
@Observable
final class RemoteChangeWatcher {
    private static let log = HamasenLog(category: "changes")
    /// How often the schedule looks for a server whose check is due. The
    /// shortest interval offered is thirty seconds, so this is fine enough.
    private static let tick = Duration.seconds(5)

    private var poll: Task<Void, Never>?
    private var mountedServers: @MainActor () -> [ServerConfig] = { [] }
    private var observe: @MainActor (ServerHealth, UUID) -> Void = { _, _ in }
    /// When each server was last checked.
    private var lastChecked: [UUID: Date] = [:]
    private var isChecking = false

    /// - Parameters:
    ///   - servers: the servers to watch, asked again on every tick, so
    ///     mounting, pausing and interval changes need no restart.
    ///   - observing: told how each server answered.
    func start(
        servers: @escaping @MainActor () -> [ServerConfig],
        observing: @escaping @MainActor (ServerHealth, UUID) -> Void
    ) {
        mountedServers = servers
        observe = observing
        guard poll == nil else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tick)
                guard !Task.isCancelled else { return }
                await self?.checkDueServers()
            }
        }
    }

    /// Checks one server straight away, for a connection just resumed or
    /// edited.
    func checkSoon(_ serverID: UUID) {
        lastChecked[serverID] = nil
    }

    func stop() {
        poll?.cancel()
        poll = nil
    }

    // MARK: - One round

    private func checkDueServers() async {
        guard !isChecking else { return }
        let now = Date()
        let due = mountedServers().filter { server in
            let interval = server.effectiveRemoteChangeIntervalSeconds
            guard interval > 0 else { return false }
            return (lastChecked[server.id] ?? .distantPast).addingTimeInterval(TimeInterval(interval)) <= now
        }
        guard !due.isEmpty else { return }
        isChecking = true
        defer { isChecking = false }
        for server in due { lastChecked[server.id] = now }
        await check(due)
    }

    private func check(_ servers: [ServerConfig]) async {
        guard let manager = try? FinderDomain.manager() else { return }
        guard let store = try? RemoteDirectorySnapshotStore() else { return }

        // The set is unavailable while the extension is being restarted,
        // which is ordinary: the servers are still checked for reachability.
        let materialized = (try? await MaterializedItems.all(from: manager)) ?? []
        let byServer = Self.directoriesToCheck(materialized)

        // Anything unmounted since the last round would otherwise be reported
        // as wholly deleted when it comes back.
        do {
            try store.keepOnly(serverIDs: Set(mountedServers().map(\.id)))
        } catch {
            Self.log.error("Could not drop the record of unmounted servers: \(error.localizedDescription)")
        }

        for server in servers {
            let (health, changes) = await Self.changes(
                on: server, directoryPaths: byServer[server.id] ?? [], store: store)
            observe(health, server.id)
            guard let summary = RemoteChangeSummary(serverName: server.name, changes: changes)
            else { continue }
            Self.log.notice("\(server.name): \(summary.message)")

            // The system's own re-enumeration is what updates Finder; the
            // notification only tells the person. The changed directories
            // are queued for the extension to report, so the window does not
            // keep showing the old listing next to a notification naming a
            // file it does not have — and that comes first, so a
            // notification never announces a change Finder was not told of.
            let changed = changes.filter { !$0.isEmpty }.map {
                DirectoryRefreshQueue.Entry(serverID: server.id, path: $0.directoryPath)
            }
            do {
                try DirectoryRefreshQueue().enqueue(changed)
            } catch {
                Self.log.error("Could not queue the refresh for \(server.name): \(error.localizedDescription)")
                continue
            }
            do {
                try await manager.signalEnumerator(for: .workingSet)
            } catch {
                // The queue keeps the refresh for the next signal, so this
                // delays Finder rather than losing the change.
                Self.log.error("Could not signal the working set: \(error.localizedDescription)")
            }
            AppNotifier.remoteChanges(summary)
        }
    }

    /// The directories worth asking about: those the system holds, plus the
    /// parents of files it holds — a downloaded file tells us its folder is
    /// one somebody is looking at.
    static func directoriesToCheck(
        _ materialized: [any NSFileProviderItemProtocol]
    ) -> [UUID: Set<String>] {
        var byServer: [UUID: Set<String>] = [:]
        for item in materialized {
            switch ItemIdentifierMapper.entity(for: item.itemIdentifier) {
            case .serverRoot(let serverID)?:
                // A server folder that was opened, even one with nothing
                // downloaded from it yet, is one somebody is looking at.
                byServer[serverID, default: []].insert(RemotePath.root)
            case .item(let serverID, let path)?:
                let directory = item.contentType == .folder ? path : RemotePath.parent(of: path)
                byServer[serverID, default: []].insert(directory)
            case .root?, nil:
                continue
            }
        }
        return byServer
    }

    /// Connects, re-lists the directories somebody has open, and says how
    /// the server answered along with what changed.
    private static func changes(
        on server: ServerConfig,
        directoryPaths: Set<String>,
        store: RemoteDirectorySnapshotStore
    ) async -> (ServerHealth, [RemoteDirectorySnapshot.Change]) {
        let service: any RemoteFileService
        do {
            let credentials = try KeychainCredentialStore().loadCredentials(for: server)
            service = try RemoteFileServiceFactory.makeService(for: server, credentials: credentials)
            try await service.connect()
        } catch {
            // A server that is down is not a server whose files all vanished.
            return (health(after: error), [])
        }
        defer { Task { try? await service.disconnect() } }

        // Compared against the record but not written to it. The extension
        // writes the record when it brings the system up to date, which the
        // signal that follows makes it do; writing here first would leave the
        // extension nothing to report, and a deleted file would stay in
        // Finder. The one exception is a directory with no record yet, which
        // `observe` gives its baseline so the next round has something to
        // compare.
        var changes: [RemoteDirectorySnapshot.Change] = []
        for path in directoryPaths.sorted() {
            guard let items = try? await service.listDirectory(at: path) else { continue }
            do {
                changes.append(try store.observe(items, serverID: server.id, directoryPath: path))
            } catch {
                Self.log.error("Could not compare \(path) on \(server.name): \(error.localizedDescription)")
            }
        }
        return (ServerHealth(state: .reachable), changes)
    }

    /// A refused credential needs the person; anything else is the network
    /// or the server, which the next round tries again.
    private static func health(after error: Error) -> ServerHealth {
        switch error {
        case RemoteFileServiceError.authenticationFailed,
             RemoteFileServiceError.hostKeyChanged,
             RemoteFileServiceError.privateKeyPassphraseRequired,
             RemoteFileServiceError.privateKeyUnreadable,
             is KeychainCredentialStore.KeychainError:
            return ServerHealth(state: .signInRequired, message: error.localizedDescription)
        default:
            return ServerHealth(state: .unreachable, message: error.localizedDescription)
        }
    }
}
