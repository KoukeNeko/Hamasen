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

    /// The system's own re-enumeration is what actually updates Finder; the
    /// notification only tells the person. Signalling it means a change found
    /// here shows up without waiting for somebody to refresh.
    private var poll: Task<Void, Never>?
    private var mountedServers: @MainActor () -> [ServerConfig] = { [] }

    private(set) var isPolling = false

    func start(servers: @escaping @MainActor () -> [ServerConfig]) {
        mountedServers = servers
        restart()
    }

    /// Called when the interval setting changes, and when servers are mounted
    /// or unmounted.
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
        var snapshot = store.load()
        snapshot.keepOnly(serverIDs: Set(servers.map(\.id)))
        try? store.save(snapshot)

        var changed = false
        for server in servers {
            guard let paths = byServer[server.id] else { continue }
            let changes = await Self.changes(
                on: server, directoryPaths: paths, store: store)
            guard let summary = RemoteChangeSummary(serverName: server.name, changes: changes)
            else { continue }
            changed = true
            Self.log.notice("\(server.name): \(summary.message)")
            await Self.notify(summary)
        }

        if changed {
            // Finder is showing what it last enumerated; without this the
            // notification would name a file the window does not have.
            try? await manager.signalEnumerator(for: .workingSet)
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

        var changes: [RemoteDirectorySnapshot.Change] = []
        for path in directoryPaths.sorted() {
            guard let items = try? await service.listDirectory(at: path) else { continue }
            changes.append(store.record(items, serverID: server.id, directoryPath: path))
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
