import FileProvider
import Foundation
import HamasenCore
import UniformTypeIdentifiers

/// The replicated File Provider extension for the single "Hamasen"
/// domain: the root lists mounted servers as folders, and everything below a
/// server folder is translated into RemoteFileService operations.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private let domain: NSFileProviderDomain
    private let registry = ConnectionRegistry()

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
    }

    func invalidate() {
        let registry = registry
        Task {
            await registry.shutdownAll()
        }
    }

    // MARK: - Metadata

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let registry = registry
        Task {
            defer { progress.completedUnitCount = 1 }

            switch ItemIdentifierMapper.entity(for: identifier) {
            case .root:
                completionHandler(RootItem(), nil)
            case .serverRoot(let serverID):
                do {
                    let config = try ConnectionRegistry.config(for: serverID)
                    completionHandler(ServerFolderItem(config: config), nil)
                } catch {
                    completionHandler(nil, FileProviderErrorMapper.map(error))
                }
            case .item(let serverID, let path):
                do {
                    let service = try await registry.service(for: serverID)
                    let info = try await service.itemInfo(at: path)
                    completionHandler(RemoteFileItem(serverID: serverID, remoteItem: info), nil)
                } catch {
                    completionHandler(nil, FileProviderErrorMapper.map(error))
                }
            case nil:
                completionHandler(nil, NSFileProviderError(.noSuchItem))
            }
        }
        return progress
    }

    // MARK: - Contents

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let registry = registry
        let domain = domain
        Task {
            defer { progress.completedUnitCount = 1 }

            guard case .item(let serverID, let path) = ItemIdentifierMapper.entity(for: itemIdentifier) else {
                completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
                return
            }
            do {
                let service = try await registry.service(for: serverID)
                let info = try await service.itemInfo(at: path)
                let localURL = try Self.makeTemporaryFileURL(for: domain)
                try await service.downloadFile(at: path, to: localURL)
                completionHandler(localURL, RemoteFileItem(serverID: serverID, remoteItem: info), nil)
            } catch {
                completionHandler(nil, nil, FileProviderErrorMapper.map(error))
            }
        }
        return progress
    }

    // MARK: - Create / Modify / Delete

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let registry = registry
        let domain = domain
        Task {
            defer { progress.completedUnitCount = 1 }

            guard let (serverID, parentPath) = Self.containerLocation(
                of: itemTemplate.parentItemIdentifier
            ) else {
                completionHandler(nil, fields, false, NSFileProviderError(.noSuchItem))
                return
            }

            let newItemPath = RemotePath.join(parentPath, itemTemplate.filename)
            do {
                let service = try await registry.service(for: serverID)
                if itemTemplate.contentType == .folder {
                    try await service.createDirectory(at: newItemPath)
                } else if let url {
                    try await service.uploadFile(from: url, to: newItemPath)
                } else {
                    // A file with no contents yet (e.g. Finder creating a
                    // placeholder): create it empty on the server.
                    let emptyFileURL = try Self.makeTemporaryFileURL(for: domain)
                    try Data().write(to: emptyFileURL)
                    defer { try? FileManager.default.removeItem(at: emptyFileURL) }
                    try await service.uploadFile(from: emptyFileURL, to: newItemPath)
                }
                let info = try await service.itemInfo(at: newItemPath)
                completionHandler(RemoteFileItem(serverID: serverID, remoteItem: info), [], false, nil)
            } catch {
                completionHandler(nil, fields, false, FileProviderErrorMapper.map(error))
            }
        }
        return progress
    }

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let registry = registry
        Task {
            defer { progress.completedUnitCount = 1 }

            guard case .item(let serverID, let currentPath) = ItemIdentifierMapper.entity(for: item.itemIdentifier) else {
                completionHandler(nil, changedFields, false, NSFileProviderError(.noSuchItem))
                return
            }
            do {
                let service = try await registry.service(for: serverID)
                var effectivePath = currentPath

                let isRenamed = changedFields.contains(.filename)
                let isReparented = changedFields.contains(.parentItemIdentifier)
                if isRenamed || isReparented {
                    let newParentPath: String
                    if isReparented {
                        guard let (targetServerID, parentPath) = Self.containerLocation(
                            of: item.parentItemIdentifier
                        ), targetServerID == serverID else {
                            // Moving between servers is not a rename; Finder
                            // falls back to copy + delete on this error.
                            throw NSFileProviderError(.noSuchItem)
                        }
                        newParentPath = parentPath
                    } else {
                        newParentPath = RemotePath.parent(of: currentPath)
                    }
                    let newName = isRenamed ? item.filename : RemotePath.name(of: currentPath)
                    let destinationPath = RemotePath.join(newParentPath, newName)
                    if destinationPath != currentPath {
                        try await service.moveItem(from: currentPath, to: destinationPath)
                        effectivePath = destinationPath
                    }
                }

                if changedFields.contains(.contents), let newContents {
                    try await service.uploadFile(from: newContents, to: effectivePath)
                }

                let info = try await service.itemInfo(at: effectivePath)
                completionHandler(RemoteFileItem(serverID: serverID, remoteItem: info), [], false, nil)
            } catch {
                completionHandler(nil, changedFields, false, FileProviderErrorMapper.map(error))
            }
        }
        return progress
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let registry = registry
        Task {
            defer { progress.completedUnitCount = 1 }

            guard case .item(let serverID, let path) = ItemIdentifierMapper.entity(for: identifier) else {
                // Server folders and the root are managed from the app.
                completionHandler(NSFileProviderError(.noSuchItem))
                return
            }
            do {
                let service = try await registry.service(for: serverID)
                let info = try await service.itemInfo(at: path)
                if info.isDirectory {
                    try await Self.deleteDirectoryRecursively(at: path, using: service)
                } else {
                    try await service.deleteFile(at: path)
                }
                completionHandler(nil)
            } catch {
                completionHandler(FileProviderErrorMapper.map(error))
            }
        }
        return progress
    }

    // MARK: - Enumeration

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        switch containerItemIdentifier {
        case .workingSet, .trashContainer:
            return EmptyEnumerator()
        case .rootContainer:
            return ServerListEnumerator()
        default:
            switch ItemIdentifierMapper.entity(for: containerItemIdentifier) {
            case .serverRoot(let serverID):
                return DirectoryEnumerator(serverID: serverID, directoryPath: RemotePath.root, registry: registry)
            case .item(let serverID, let path):
                return DirectoryEnumerator(serverID: serverID, directoryPath: path, registry: registry)
            case .root, nil:
                throw NSFileProviderError(.noSuchItem)
            }
        }
    }

    // MARK: - Helpers

    /// Resolves a container identifier to (server, directory path) for
    /// creating or moving items. Returns nil for the domain root, which does
    /// not accept items.
    private static func containerLocation(
        of identifier: NSFileProviderItemIdentifier
    ) -> (serverID: UUID, path: String)? {
        switch ItemIdentifierMapper.entity(for: identifier) {
        case .serverRoot(let serverID):
            return (serverID, RemotePath.root)
        case .item(let serverID, let path):
            return (serverID, path)
        case .root, nil:
            return nil
        }
    }

    /// Download targets must live in the provider's temporary directory so
    /// the system can claim them without copying across volumes.
    private static func makeTemporaryFileURL(for domain: NSFileProviderDomain) throws -> URL {
        let manager = NSFileProviderManager(for: domain)
        let temporaryDirectory: URL
        if let providerTemporaryDirectory = try? manager?.temporaryDirectoryURL() {
            temporaryDirectory = providerTemporaryDirectory
        } else {
            temporaryDirectory = FileManager.default.temporaryDirectory
        }
        return temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    /// SFTP rmdir requires empty directories, so deletion walks the tree
    /// depth-first.
    private static func deleteDirectoryRecursively(
        at path: String,
        using service: any RemoteFileService
    ) async throws {
        let children = try await service.listDirectory(at: path)
        for child in children {
            if child.isDirectory {
                try await deleteDirectoryRecursively(at: child.path, using: service)
            } else {
                try await service.deleteFile(at: child.path)
            }
        }
        try await service.deleteDirectory(at: path)
    }
}
