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

/// Lists a directory and tells a change observer what the system should now
/// hold for it.
///
/// Every current item goes out as updated, and the system keeps the ones
/// whose version did not move. Nothing here can tell a pin from an edit on
/// the server, and that is the point: the pin lives in the metadata version,
/// so an item pinned a moment ago comes back different and Finder redraws
/// it. Deletions come from the record of the last listing, which is why the
/// record is written here, as the system is told, and not by the poll that
/// noticed the change. A directory with no record yet has no known deletions,
/// so its first refresh only updates; the record it writes serves the next.
///
/// "Every current item" costs no spurious re-download: the content version
/// comes from `RemoteItem.contentVersionToken`, the same derivation the
/// record diffs, so an item the server did not change comes back with the
/// version the system already holds.
enum DirectoryRefresh {
    @discardableResult
    static func report(
        serverID: UUID,
        directoryPath: String,
        registry: ConnectionRegistry,
        to observer: NSFileProviderChangeObserver
    ) async throws -> [RemoteItem] {
        let service = try await registry.service(for: serverID)
        let items = try await service.listDirectory(at: directoryPath)
        let change = await RemoteDirectoryRecord.changes(
            afterRecording: items, serverID: serverID, directoryPath: directoryPath)
        observer.didUpdate(items.map { RemoteFileItem(serverID: serverID, remoteItem: $0) })
        let removed = identifiers(ofRemoved: change?.removedNames ?? [], serverID: serverID, directoryPath: directoryPath)
        if !removed.isEmpty {
            observer.didDeleteItems(withIdentifiers: removed)
        }
        return items
    }

    static func identifiers(
        ofRemoved names: [String], serverID: UUID, directoryPath: String
    ) -> [NSFileProviderItemIdentifier] {
        names.map { name in
            ItemIdentifierMapper.identifier(
                for: .item(serverID: serverID, path: RemotePath.join(directoryPath, name)))
        }
    }
}
