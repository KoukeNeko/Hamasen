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

/// The domain's trash. Nothing ever goes in it — items do not allow
/// trashing, so Finder deletes outright — but the system keeps one per
/// domain on disk and has to be able to ask about it. Answering "no such
/// item" left the system's copy dataless and its import of the domain
/// failing on that one folder, retried for hours; and while a domain is
/// importing, the system downloads nothing in the background, so a pinned
/// file stayed a placeholder for days.
final class TrashItem: NSObject, NSFileProviderItem {
    private static let name = ".Trash"

    var itemIdentifier: NSFileProviderItemIdentifier { .trashContainer }
    var parentItemIdentifier: NSFileProviderItemIdentifier { .trashContainer }
    var filename: String { Self.name }
    var contentType: UTType { .folder }

    var capabilities: NSFileProviderItemCapabilities {
        [.allowsReading, .allowsContentEnumerating]
    }

    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(
            contentVersion: Data("trash".utf8),
            metadataVersion: Data("trash".utf8)
        )
    }
}

/// A server's top-level folder (named after the server). Managed from the
/// app, so Finder cannot rename, move, or delete it.
final class ServerFolderItem: NSObject, NSFileProviderItem, NSFileProviderItemDecorating {
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

    /// "Paused" beside the folder's name, so a server whose files stopped
    /// syncing says so where they are.
    var decorations: [NSFileProviderItemDecorationIdentifier]? {
        config.isPaused ? [.paused] : nil
    }

    var userInfo: [AnyHashable: Any]? {
        [RemoteFileItem.protocolUserInfoKey: config.transferProtocol.rawValue]
    }

    /// The color chosen in the app, as a Finder tag.
    var tagData: Data? {
        config.finderAppearance.tagData
    }

    /// The symbol or emoji chosen in the app, in the attribute Finder's
    /// Customize Folder writes.
    var extendedAttributes: [String: Data] {
        guard let icon = config.finderAppearance.iconAttribute else { return [:] }
        return [FinderAppearance.iconAttributeName: icon]
    }

    /// Bumped whenever this class changes what it reports, for the same
    /// reason as `RemoteFileItem.metadataRevision`.
    private static let metadataRevision = "2"

    var itemVersion: NSFileProviderItemVersion {
        // Derived from the name so a rename in the app propagates to Finder,
        // and from the storage mode so a change of mode does too.
        let versionToken = Data("\(config.finderItemToken)-\(Self.metadataRevision)".utf8)
        return NSFileProviderItemVersion(contentVersion: versionToken, metadataVersion: versionToken)
    }
}

/// A file or directory inside a server, adapted from a RemoteItem.
final class RemoteFileItem: NSObject, NSFileProviderItem, NSFileProviderItemDecorating {
    /// The key the Info.plist activation rules read to decide whether to
    /// offer "keep on this Mac" or "stop keeping".
    static let pinnedUserInfoKey = "isPinned"
    /// The server's protocol, which decides the entries that need one: a
    /// browser for WebDAV, S3 and cloud drives, a terminal for SFTP.
    static let protocolUserInfoKey = "protocol"

    /// Bumped whenever this class changes what it reports about an item.
    ///
    /// The system keeps the metadata it was last given and only asks again
    /// when the version changes. Deriving the version from the remote file
    /// alone means a change here — a capability, a content type — never
    /// reaches items already in the replica, because nothing about the file
    /// itself moved. Only the metadata version carries it: putting it in the
    /// content version would re-download every file.
    private static let metadataRevision = "4"

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
        var info: [AnyHashable: Any] = [Self.pinnedUserInfoKey: isPinned]
        info[Self.protocolUserInfoKey] = ServerProtocols.transferProtocol(of: serverID)?.rawValue
        return info
    }

    var decorations: [NSFileProviderItemDecorationIdentifier]? {
        isPinned ? [.pinned] : nil
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
        let contentVersion = remoteItem.contentVersionToken
        let contentToken = Data(contentVersion.utf8)
        // The pin travels in the metadata version, or the system keeps the
        // old policy and the old menu entry after the user pins an item.
        let metadataToken = Data(
            "\(contentVersion)-\(Self.metadataRevision)-\(isPinned)".utf8
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
            var capabilities: NSFileProviderItemCapabilities = [
                .allowsReading,
                .allowsWriting,
                .allowsRenaming,
                .allowsReparenting,
                .allowsDeleting,
                .legacyEvictionPermission,
            ]
            // A file the server says cannot be written — a Google document
            // exported as Office, a read-only file on a share — opens as a
            // locked document instead of failing on save.
            if let permissions = remoteItem.permissions, permissions & 0o222 == 0 {
                capabilities.remove(.allowsWriting)
            }
            return capabilities
        }
    }
}

/// The badges declared in the extension's Info.plist, by identifier.
extension NSFileProviderItemDecorationIdentifier {
    static let pinned = NSFileProviderItemDecorationIdentifier("dev.hamasen.decoration.pinned")
    static let paused = NSFileProviderItemDecorationIdentifier("dev.hamasen.decoration.paused")
}
