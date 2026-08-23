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

/// Enumerates the mounted servers as folders.
///
/// Used for both the domain root (what Finder shows when the location is
/// opened) and the working set. The working set matters because a replicated
/// extension only receives change signals for that container — signals for
/// any other container are ignored by the system — so mount, unmount, and
/// rename changes have to be reported here to reach Finder.
///
/// The previous server list is carried inside the sync anchor, which is what
/// lets `enumerateChanges` report a precise diff without keeping state
/// between calls.
final class ServerListEnumerator: NSObject, NSFileProviderEnumerator {
    func invalidate() {}

    private static func anchor(for configs: [ServerConfig]) -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(
            ServerListChangeTracker.encode(ServerListChangeTracker.snapshot(of: configs))
        )
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        do {
            let items = try ConnectionRegistry.mountedConfigs().map(ServerFolderItem.init)
            observer.didEnumerate(items)
            observer.finishEnumerating(upTo: nil)
        } catch {
            observer.finishEnumeratingWithError(FileProviderErrorMapper.map(error))
        }
    }

    /// What the server list looks like now, and how that differs from the
    /// list the anchor was made from.
    struct PendingChanges {
        let configs: [ServerConfig]
        let diff: ServerListChangeTracker.Diff
    }

    /// Read errors must not reach the diff: an empty list would be reported
    /// as "every server was deleted" and wipe them from Finder.
    static func pendingChanges(since anchor: NSFileProviderSyncAnchor) throws -> PendingChanges {
        let configs = try ConnectionRegistry.mountedConfigs()
        let diff = ServerListChangeTracker.diff(
            previous: ServerListChangeTracker.decode(anchor.rawValue),
            current: configs
        )
        return PendingChanges(configs: configs, diff: diff)
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        do {
            report(try Self.pendingChanges(since: anchor), to: observer)
        } catch {
            observer.finishEnumeratingWithError(FileProviderErrorMapper.map(error))
        }
    }

    func report(_ changes: PendingChanges, to observer: NSFileProviderChangeObserver) {
        let diff = changes.diff
        if !diff.updated.isEmpty {
            observer.didUpdate(diff.updated.map(ServerFolderItem.init))
        }
        if !diff.removedServerIDs.isEmpty {
            observer.didDeleteItems(
                withIdentifiers: diff.removedServerIDs.compactMap { serverID in
                    UUID(uuidString: serverID).map {
                        ItemIdentifierMapper.identifier(for: .serverRoot($0))
                    }
                }
            )
        }
        observer.finishEnumeratingChanges(upTo: Self.anchor(for: changes.configs), moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        // No anchor rather than one built from an empty list. The system
        // reads nil as "no common ground, enumerate from scratch", where an
        // anchor claiming the mount was empty would make the next diff read
        // as every server having been deleted — the very thing
        // enumerateChanges refuses to do.
        guard let configs = try? ConnectionRegistry.mountedConfigs() else {
            completionHandler(nil)
            return
        }
        completionHandler(Self.anchor(for: configs))
    }
}

/// Enumerates one remote directory of one server.
final class DirectoryEnumerator: NSObject, NSFileProviderEnumerator {
    private let serverID: UUID
    private let directoryPath: String
    private let registry: ConnectionRegistry

    init(serverID: UUID, directoryPath: String, registry: ConnectionRegistry) {
        self.serverID = serverID
        self.directoryPath = directoryPath
        self.registry = registry
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let serverID = serverID
        let directoryPath = directoryPath
        let registry = registry
        Task {
            do {
                let service = try await registry.service(for: serverID)
                let items = try await service.listDirectory(at: directoryPath)
                observer.didEnumerate(items.map { RemoteFileItem(serverID: serverID, remoteItem: $0) })
                // Every listing is a free observation of what is there. The
                // poll that looks for changes has nothing to compare against
                // unless the browsing that happens anyway writes it down.
                RemoteDirectoryRecord.record(items, serverID: serverID, directoryPath: directoryPath)
                observer.finishEnumerating(upTo: nil)
            } catch {
                observer.finishEnumeratingWithError(FileProviderErrorMapper.map(error))
            }
        }
    }

    /// Brings the system's copy of the directory up to date with the server's.
    ///
    /// Every current item goes out as updated, and the system keeps the ones
    /// whose version did not move. Nothing here can tell a pin from an edit
    /// on the server, and that is the point: the pin lives in the metadata
    /// version, so an item pinned a moment ago comes back different and
    /// Finder redraws it. Deletions come from the record, which is why the
    /// record is written here, as the system is told, and not by the poll
    /// that noticed the change.
    ///
    /// The anchor carries nothing: the record is the state, so any anchor
    /// the system hands back gets the same answer.
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let serverID = serverID
        let directoryPath = directoryPath
        let registry = registry
        Task {
            do {
                let service = try await registry.service(for: serverID)
                let items = try await service.listDirectory(at: directoryPath)
                let change = await RemoteDirectoryRecord.changes(
                    afterRecording: items, serverID: serverID, directoryPath: directoryPath)
                observer.didUpdate(items.map { RemoteFileItem(serverID: serverID, remoteItem: $0) })
                let removed = (change?.removedNames ?? []).map { name in
                    ItemIdentifierMapper.identifier(
                        for: .item(serverID: serverID, path: RemotePath.join(directoryPath, name)))
                }
                if !removed.isEmpty {
                    observer.didDeleteItems(withIdentifiers: removed)
                }
                observer.finishEnumeratingChanges(upTo: Self.anchor(), moreComing: false)
            } catch {
                observer.finishEnumeratingWithError(FileProviderErrorMapper.map(error))
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(Self.anchor())
    }

    private static func anchor() -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(Data(Date().ISO8601Format().utf8))
    }
}

/// Enumerator for containers the MVP does not track (e.g. the working set):
/// always empty.
final class EmptyEnumerator: NSObject, NSFileProviderEnumerator {
    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Data("empty".utf8)))
    }
}
