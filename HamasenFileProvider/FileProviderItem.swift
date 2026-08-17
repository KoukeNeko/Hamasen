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

    init(serverID: UUID, remoteItem: RemoteItem) {
        self.serverID = serverID
        self.remoteItem = remoteItem
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
        let metadataToken = Data("\(remoteItem.size)-\(modificationEpoch)-\(Self.metadataRevision)".utf8)
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
                // Deprecated in favour of NSFileProviderContentPolicy, but
                // still enforced: without it the system refuses every
                // eviction with NSFileProviderErrorNonEvictable, whatever the
                // content policy says.
                .allowsEvicting,
            ]
        }
    }
}
