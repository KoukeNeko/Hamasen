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

    var itemVersion: NSFileProviderItemVersion {
        // Derived from the name so a rename in the app propagates to Finder.
        let versionToken = Data("\(config.name)".utf8)
        return NSFileProviderItemVersion(contentVersion: versionToken, metadataVersion: versionToken)
    }
}

/// A file or directory inside a server, adapted from a RemoteItem.
final class RemoteFileItem: NSObject, NSFileProviderItem {
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
        let versionToken = Data("\(remoteItem.size)-\(modificationEpoch)".utf8)
        return NSFileProviderItemVersion(contentVersion: versionToken, metadataVersion: versionToken)
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
            ]
        }
    }
}
