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
            observer.didEnumerate(configs.map(ServerFolderItem.init))
        }

        guard let pending = walk.current else {
            store.clear()
            observer.finishEnumerating(upTo: nil)
            return
        }

        let registry = registry
        Task {
            do {
                let service = try await registry.service(for: pending.serverID)
                let items = try await service.listDirectory(at: pending.path)
                observer.didEnumerate(items.map { RemoteFileItem(serverID: pending.serverID, remoteItem: $0) })
                RemoteDirectoryRecord.record(
                    items, serverID: pending.serverID, directoryPath: pending.path)
                walk.advance(subdirectories: items.filter(\.isDirectory).map(\.name))
            } catch {
                // One directory the account cannot read, or one server that
                // is down, must not end the walk for every other server.
                Self.log.notice("Skipping \(pending.path) on \(pending.serverID): \(error.localizedDescription)")
                walk.skipCurrent()
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

            if walk.isFinished {
                store.clear()
                observer.finishEnumerating(upTo: nil)
            } else {
                observer.finishEnumerating(upTo: NSFileProviderPage(WorkingSetWalk.encode(walk.token)))
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        serverList.enumerateChanges(for: observer, from: anchor)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        serverList.currentSyncAnchor(completionHandler: completionHandler)
    }
}
