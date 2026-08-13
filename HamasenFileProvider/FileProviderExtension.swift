import FileProvider
import Foundation
import HamasenCore
import UniformTypeIdentifiers

/// The replicated File Provider extension for the single "Hamasen"
/// domain: the root lists mounted servers as folders, and everything below a
/// server folder is translated into RemoteFileService operations.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension,
    NSFileProviderPartialContentFetching {
    /// The item fields this provider can actually persist. Anything else is
    /// echoed back as still-pending, which is how the system is told a field
    /// is unsupported; reporting an error instead would mark the item as
    /// broken in Finder.
    private static let modifiableFields: NSFileProviderItemFields = [
        .filename,
        .parentItemIdentifier,
        .contents,
    ]

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

    // MARK: - Partial contents

    /// Fetches only the byte range the system asked for, so opening a large
    /// file does not download all of it. Both protocols read at an offset:
    /// SFTP natively, WebDAV through a Range request.
    func fetchPartialContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion,
        request: NSFileProviderRequest,
        minimalRange requestedRange: NSRange,
        aligningTo alignment: Int,
        options: NSFileProviderFetchContentsOptions = [],
        completionHandler: @escaping (
            URL?, NSFileProviderItem?, NSRange, NSFileProviderMaterializationFlags, Error?
        ) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let registry = registry
        let domain = domain

        guard case .item(let serverID, let path) = ItemIdentifierMapper.entity(for: itemIdentifier) else {
            completionHandler(nil, nil, NSRange(location: 0, length: 0), [], NSFileProviderError(.noSuchItem))
            progress.completedUnitCount = 1
            return progress
        }

        let task = Task {
            defer { progress.completedUnitCount = 1 }
            do {
                let service = try await registry.service(for: serverID)
                let info = try await service.itemInfo(at: path)

                // A server that does not report a size leaves no way to align
                // a range; fetching the whole item is the only way to avoid
                // handing back an empty file that looks correctly versioned.
                guard info.size > 0 else {
                    let localURL = try Self.makeTemporaryFileURL(for: domain)
                    try await service.downloadFile(at: path, to: localURL)
                    let attributes = try? FileManager.default.attributesOfItem(atPath: localURL.path)
                    let byteCount = (attributes?[.size] as? NSNumber)?.intValue ?? 0
                    completionHandler(
                        localURL,
                        RemoteFileItem(serverID: serverID, remoteItem: info),
                        NSRange(location: 0, length: byteCount),
                        [],
                        nil
                    )
                    return
                }

                let range = ByteRangeAlignment.align(
                    offset: Int64(requestedRange.location),
                    length: requestedRange.length,
                    alignment: alignment,
                    fileSize: info.size
                )

                let contents = try await service.downloadRange(
                    at: path,
                    offset: range.offset,
                    length: range.length
                )
                try Task.checkCancellation()

                let localURL = try Self.makeTemporaryFileURL(for: domain)
                try Self.write(contents, at: range.offset, to: localURL)

                completionHandler(
                    localURL,
                    RemoteFileItem(serverID: serverID, remoteItem: info),
                    NSRange(location: Int(range.offset), length: contents.count),
                    [],
                    nil
                )
            } catch is CancellationError {
                completionHandler(nil, nil, requestedRange, [], CocoaError(.userCancelled))
            } catch {
                completionHandler(nil, nil, requestedRange, [], FileProviderErrorMapper.map(error))
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    /// Writes a fetched range at its own offset, leaving the rest of the file
    /// sparse: the system only reads the range that was reported.
    private static func write(_ contents: Data, at offset: Int64, to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.seek(toOffset: UInt64(offset))
        try file.write(contentsOf: contents)
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

            let serverID: UUID
            let currentPath: String
            switch ItemIdentifierMapper.entity(for: item.itemIdentifier) {
            case .item(let itemServerID, let itemPath):
                serverID = itemServerID
                currentPath = itemPath
            case .serverRoot(let folderServerID):
                // Server folders are configured in the app, but Finder still
                // stamps metadata such as lastUsedDate on them when they are
                // opened. Accept the call and report the fields as unsupported.
                do {
                    let config = try ConnectionRegistry.config(for: folderServerID)
                    completionHandler(ServerFolderItem(config: config), changedFields, false, nil)
                } catch {
                    completionHandler(nil, changedFields, false, FileProviderErrorMapper.map(error))
                }
                return
            case .root:
                completionHandler(RootItem(), changedFields, false, nil)
                return
            case nil:
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
                completionHandler(
                    RemoteFileItem(serverID: serverID, remoteItem: info),
                    changedFields.subtracting(Self.modifiableFields),
                    false,
                    nil
                )
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
        case .trashContainer:
            return EmptyEnumerator()
        case .rootContainer, .workingSet:
            // The working set is how a replicated extension propagates
            // changes, so it enumerates the same server folders as the root.
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
