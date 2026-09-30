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

    private var poll: Task<Void, Never>?
    private var mountedServers: @MainActor () -> [ServerConfig] = { [] }

    private(set) var isPolling = false

    func start(servers: @escaping @MainActor () -> [ServerConfig]) {
        mountedServers = servers
        restart()
    }

    /// Called when the interval setting changes. Mounting and unmounting need
    /// no restart: each round asks for the mounted servers again.
    func restart() {
        poll?.cancel()
        poll = nil
        isPolling = false

        guard let interval = AppSettings.remoteChangePollInterval() else { return }
        isPolling = true
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                await self?.check()
            }
        }
    }

    func stop() {
        poll?.cancel()
        poll = nil
        isPolling = false
    }

    // MARK: - One round

    private func check() async {
        let servers = mountedServers()
        guard !servers.isEmpty, let manager = try? FinderDomain.manager() else { return }
        guard let store = try? RemoteDirectorySnapshotStore() else { return }

        guard let materialized = try? await MaterializedItems.all(from: manager) else {
            // The set is unavailable while the extension is being restarted,
            // which is ordinary and not worth reporting.
            return
        }

        let byServer = Self.directoriesToCheck(materialized)
        guard !byServer.isEmpty else { return }

        // Anything unmounted since the last round would otherwise be reported
        // as wholly deleted when it comes back.
        do {
            try store.keepOnly(serverIDs: Set(servers.map(\.id)))
        } catch {
            Self.log.error("Could not drop the record of unmounted servers: \(error.localizedDescription)")
        }

        for server in servers {
            guard let paths = byServer[server.id] else { continue }
            let changes = await Self.changes(
                on: server, directoryPaths: paths, store: store)
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
            await Self.notify(summary)
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
            guard case .item(let serverID, let path)? =
                ItemIdentifierMapper.entity(for: item.itemIdentifier)
            else { continue }
            let directory = item.contentType == .folder ? path : RemotePath.parent(of: path)
            byServer[serverID, default: []].insert(directory)
        }
        return byServer
    }

    private static func changes(
        on server: ServerConfig,
        directoryPaths: Set<String>,
        store: RemoteDirectorySnapshotStore
    ) async -> [RemoteDirectorySnapshot.Change] {
        guard let credentials = try? KeychainCredentialStore().loadCredentials(for: server)
        else { return [] }
        let service = RemoteFileServiceFactory.makeService(for: server, credentials: credentials)
        guard (try? await service.connect()) != nil else {
            // A server that is down is not a server whose files all vanished.
            return []
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
        return changes
    }

    // MARK: - Telling the user

    private static func notify(_ summary: RemoteChangeSummary) async {
        let center = UNUserNotificationCenter.current()
        guard let granted = try? await center.requestAuthorization(options: [.alert]), granted
        else { return }

        let content = UNMutableNotificationContent()
        content.title = summary.title
        content.body = summary.message

        // Delivered now: a trigger of nil means immediately, and a change
        // already found has nothing to wait for.
        try? await center.add(UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
