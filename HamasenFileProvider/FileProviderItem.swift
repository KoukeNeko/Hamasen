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
import UniformTypeIdentifiers

/// The domain root ("Hamasen" itself).
final class RootItem: NSObject, NSFileProviderItem {
    var itemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var parentItemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var filename: String { SharedConstants.mainDomainDisplayName }
    var contentType: UTType { .folder }

    var capabilities: NSFileProviderItemCapabilities {
        [.allowsReading, .allowsContentEnumerating]
    }

    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(
            contentVersion: Data("root".utf8),
            metadataVersion: Data("root".utf8)
        )
    }
}

/// A server's top-level folder (named after the server). Managed from the
/// app, so Finder cannot rename, move, or delete it.
final class ServerFolderItem: NSObject, NSFileProviderItem {
    private let config: ServerConfig

    init(config: ServerConfig) {
        self.config = config
    }

    var itemIdentifier: NSFileProviderItemIdentifier {
        ItemIdentifierMapper.identifier(for: .serverRoot(config.id))
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var filename: String { config.name }
    var contentType: UTType { .folder }

    var capabilities: NSFileProviderItemCapabilities {
        [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems]
    }

    /// Set here rather than on every item: everything inside a server folder
    /// inherits, so one value governs the whole server.
    var contentPolicy: NSFileProviderContentPolicy {
        config.storageMode.contentPolicy
    }

    var itemVersion: NSFileProviderItemVersion {
        // Derived from the name so a rename in the app propagates to Finder,
        // and from the storage mode so a change of mode does too.
        let versionToken = Data(config.finderItemToken.utf8)
        return NSFileProviderItemVersion(contentVersion: versionToken, metadataVersion: versionToken)
    }
}

/// A file or directory inside a server, adapted from a RemoteItem.
final class RemoteFileItem: NSObject, NSFileProviderItem {
    /// The key the Info.plist activation rules read to decide whether to
    /// offer "keep on this Mac" or "stop keeping".
    static let pinnedUserInfoKey = "isPinned"

    /// Bumped whenever this class changes what it reports about an item.
    ///
    /// The system keeps the metadata it was last given and only asks again
    /// when the version changes. Deriving the version from the remote file
    /// alone means a change here — a capability, a content type — never
    /// reaches items already in the replica, because nothing about the file
    /// itself moved. Only the metadata version carries it: putting it in the
    /// content version would re-download every file.
    private static let metadataRevision = "2"

    private let serverID: UUID
    private let remoteItem: RemoteItem
    private let isPinned: Bool

    /// The pin is looked up rather than passed in, so every site that vends
    /// an item reports it without having to remember to.
    init(serverID: UUID, remoteItem: RemoteItem, isPinned: Bool? = nil) {
        self.serverID = serverID
        self.remoteItem = remoteItem
        self.isPinned = isPinned ?? PinnedItems.contains(
            ItemIdentifierMapper.identifier(for: .item(serverID: serverID, path: remoteItem.path))
        )
    }

    private var entity: ProviderEntity {
        .item(serverID: serverID, path: remoteItem.path)
    }

    var itemIdentifier: NSFileProviderItemIdentifier {
        ItemIdentifierMapper.identifier(for: entity)
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        ItemIdentifierMapper.identifier(for: ItemIdentifierMapper.parentEntity(of: entity))
    }

    var filename: String {
        remoteItem.name
    }

    var contentType: UTType {
        switch remoteItem.kind {
        case .directory:
            return .folder
        case .symlink:
            return .symbolicLink
        case .file:
            let fileExtension = (remoteItem.name as NSString).pathExtension
            return UTType(filenameExtension: fileExtension) ?? .data
        }
    }

    var userInfo: [AnyHashable: Any]? {
        [Self.pinnedUserInfoKey: isPinned]
    }

    /// A pinned item is downloaded and kept; everything else inherits its
    /// server folder's policy.
    var contentPolicy: NSFileProviderContentPolicy {
        isPinned ? .downloadEagerlyAndKeepDownloaded : .inherited
    }

    var documentSize: NSNumber? {
        remoteItem.kind == .file ? NSNumber(value: remoteItem.size) : nil
    }

    var contentModificationDate: Date? {
        remoteItem.modificationDate
    }

    var itemVersion: NSFileProviderItemVersion {
        // Version derived from size + mtime: enough for the system to detect
        // remote content changes between enumerations.
        let modificationEpoch = remoteItem.modificationDate?.timeIntervalSince1970 ?? 0
        let contentToken = Data("\(remoteItem.size)-\(modificationEpoch)".utf8)
        // The pin travels in the metadata version, or the system keeps the
        // old policy and the old menu entry after the user pins an item.
        let metadataToken = Data(
            "\(remoteItem.size)-\(modificationEpoch)-\(Self.metadataRevision)-\(isPinned)".utf8
        )
        return NSFileProviderItemVersion(contentVersion: contentToken, metadataVersion: metadataToken)
    }

    var capabilities: NSFileProviderItemCapabilities {
        switch remoteItem.kind {
        case .directory:
            return [
                .allowsReading,
                .allowsContentEnumerating,
                .allowsAddingSubItems,
                .allowsRenaming,
                .allowsReparenting,
                .allowsDeleting,
            ]
        case .file, .symlink:
            return [
                .allowsReading,
                .allowsWriting,
                .allowsRenaming,
                .allowsReparenting,
                .allowsDeleting,
                .legacyEvictionPermission,
            ]
        }
    }
}
