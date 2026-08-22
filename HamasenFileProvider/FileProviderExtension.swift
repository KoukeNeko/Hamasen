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
        switch ItemIdentifierMapper.entity(for: identifier) {
        case .root:
            completionHandler(RootItem(), nil)
            return Self.answered()
        case .serverRoot(let serverID):
            do {
                completionHandler(ServerFolderItem(config: try ConnectionRegistry.config(for: serverID)), nil)
            } catch {
                completionHandler(nil, FileProviderErrorMapper.map(error))
            }
            return Self.answered()
        case .item, nil:
            return performing(at: Self.location(of: identifier)) { service, location in
                RemoteFileItem(
                    serverID: location.serverID,
                    remoteItem: try await service.itemInfo(at: location.path)
                )
            } answer: { result in
                switch result {
                case .success(let item): completionHandler(item, nil)
                case .failure(let error): completionHandler(nil, error)
                }
            }
        }
    }

    // MARK: - Contents

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let domain = domain
        return performing(at: Self.location(of: itemIdentifier)) { service, location in
            let info = try await service.itemInfo(at: location.path)
            let localURL = try Self.makeTemporaryFileURL(for: domain)
            try await service.downloadFile(at: location.path, to: localURL)
            return (localURL, RemoteFileItem(serverID: location.serverID, remoteItem: info))
        } answer: { result in
            switch result {
            case .success(let (localURL, item)): completionHandler(localURL, item, nil)
            case .failure(let error): completionHandler(nil, nil, error)
            }
        }
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
        let domain = domain
        return performing(at: Self.location(of: itemIdentifier)) { service, location in
            let info = try await service.itemInfo(at: location.path)

            // A server that does not report a size leaves no way to align a
            // range; fetching the whole item is the only way to avoid handing
            // back an empty file that looks correctly versioned.
            guard info.size > 0 else {
                let localURL = try Self.makeTemporaryFileURL(for: domain)
                try await service.downloadFile(at: location.path, to: localURL)
                let attributes = try? FileManager.default.attributesOfItem(atPath: localURL.path)
                let byteCount = (attributes?[.size] as? NSNumber)?.intValue ?? 0
                return FetchedRange(
                    localURL: localURL,
                    item: RemoteFileItem(serverID: location.serverID, remoteItem: info),
                    range: NSRange(location: 0, length: byteCount)
                )
            }

            let range = ByteRangeAlignment.align(
                offset: Int64(requestedRange.location),
                length: requestedRange.length,
                alignment: alignment,
                fileSize: info.size
            )
            let contents = try await service.downloadRange(
                at: location.path,
                offset: range.offset,
                length: range.length
            )
            try Task.checkCancellation()

            let localURL = try Self.makeTemporaryFileURL(for: domain)
            try Self.write(contents, at: range.offset, to: localURL)
            return FetchedRange(
                localURL: localURL,
                item: RemoteFileItem(serverID: location.serverID, remoteItem: info),
                range: NSRange(location: Int(range.offset), length: contents.count)
            )
        } answer: { result in
            switch result {
            case .success(let fetched):
                completionHandler(fetched.localURL, fetched.item, fetched.range, [], nil)
            case .failure(let error):
                // The range is echoed back so the system knows which request
                // failed, not that anything was fetched.
                completionHandler(nil, nil, requestedRange, [], error)
            }
        }
    }

    /// The bytes one partial fetch produced, kept together so the operation
    /// returns a value rather than calling back from inside itself.
    private struct FetchedRange {
        let localURL: URL
        let item: NSFileProviderItem
        let range: NSRange
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
        let domain = domain
        return performing(
            at: Self.containerLocation(of: itemTemplate.parentItemIdentifier)
        ) { service, parent in
            let newItemPath = RemotePath.join(parent.path, itemTemplate.filename)
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
            return RemoteFileItem(
                serverID: parent.serverID,
                remoteItem: try await service.itemInfo(at: newItemPath)
            )
        } answer: { result in
            switch result {
            case .success(let item): completionHandler(item, [], false, nil)
            case .failure(let error): completionHandler(nil, fields, false, error)
            }
        }
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
        switch ItemIdentifierMapper.entity(for: item.itemIdentifier) {
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
            return Self.answered()
        case .root:
            completionHandler(RootItem(), changedFields, false, nil)
            return Self.answered()
        case .item, nil:
            break
        }

        return performing(at: Self.location(of: item.itemIdentifier)) { service, location in
            var effectivePath = location.path

            let isRenamed = changedFields.contains(.filename)
            let isReparented = changedFields.contains(.parentItemIdentifier)
            if isRenamed || isReparented {
                let newParentPath: String
                if isReparented {
                    guard let parent = Self.containerLocation(of: item.parentItemIdentifier),
                          parent.serverID == location.serverID else {
                        // Moving between servers is not a rename; Finder
                        // falls back to copy + delete on this error.
                        throw NSFileProviderError(.noSuchItem)
                    }
                    newParentPath = parent.path
                } else {
                    newParentPath = RemotePath.parent(of: location.path)
                }
                let newName = isRenamed ? item.filename : RemotePath.name(of: location.path)
                let destinationPath = RemotePath.join(newParentPath, newName)
                if destinationPath != location.path {
                    try await service.moveItem(from: location.path, to: destinationPath)
                    effectivePath = destinationPath
                }
            }

            if changedFields.contains(.contents), let newContents {
                try await service.uploadFile(from: newContents, to: effectivePath)
            }

            return RemoteFileItem(
                serverID: location.serverID,
                remoteItem: try await service.itemInfo(at: effectivePath)
            )
        } answer: { result in
            switch result {
            case .success(let item):
                completionHandler(item, changedFields.subtracting(Self.modifiableFields), false, nil)
            case .failure(let error):
                completionHandler(nil, changedFields, false, error)
            }
        }
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        // Server folders and the root are managed from the app, so anything
        // that is not an item on a server resolves to no location.
        performing(at: Self.location(of: identifier)) { service, location in
            if try await service.itemInfo(at: location.path).isDirectory {
                // Recursive by contract: WebDAV does it in one request,
                // SFTP walks the tree itself.
                try await service.deleteDirectory(at: location.path)
            } else {
                try await service.deleteFile(at: location.path)
            }
        } answer: { result in
            switch result {
            case .success: completionHandler(nil)
            case .failure(let error): completionHandler(error)
            }
        }
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

    // MARK: - Running one operation

    /// Somewhere on a server that an operation acts on.
    struct ItemLocation {
        let serverID: UUID
        let path: String
    }

    /// Runs one server-side operation the way every entry point here runs
    /// one: on a progress the system can watch, against the connection for
    /// that item's server, answering exactly once and only ever with an
    /// error the system accepts.
    ///
    /// This shape was written out at each entry point before, which is why a
    /// session that died had to be handled in the connection registry: there
    /// was no single place where "how an operation runs" could be changed.
    private func performing<Success>(
        at location: ItemLocation?,
        work: @escaping (any RemoteFileService, ItemLocation) async throws -> Success,
        answer: @escaping (Result<Success, Error>) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let registry = registry
        let task = Task {
            defer { progress.completedUnitCount = 1 }
            guard let location else {
                answer(.failure(NSFileProviderError(.noSuchItem)))
                return
            }
            do {
                let service = try await registry.service(for: location.serverID)
                answer(.success(try await work(service, location)))
            } catch is CancellationError {
                answer(.failure(CocoaError(.userCancelled)))
            } catch {
                answer(.failure(FileProviderErrorMapper.map(error)))
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    /// A progress for an answer that took no work, so a synchronous reply
    /// still returns what the system expects.
    private static func answered() -> Progress {
        let progress = Progress(totalUnitCount: 1)
        progress.completedUnitCount = 1
        return progress
    }

    // MARK: - Helpers

    /// The item an identifier names, or nil for anything that is not a file
    /// or folder on a server.
    private static func location(
        of identifier: NSFileProviderItemIdentifier
    ) -> ItemLocation? {
        guard case .item(let serverID, let path) = ItemIdentifierMapper.entity(for: identifier) else {
            return nil
        }
        return ItemLocation(serverID: serverID, path: path)
    }

    /// Resolves a container identifier to the directory items are created in
    /// or moved to. Returns nil for the domain root, which accepts none.
    private static func containerLocation(
        of identifier: NSFileProviderItemIdentifier
    ) -> ItemLocation? {
        switch ItemIdentifierMapper.entity(for: identifier) {
        case .serverRoot(let serverID):
            return ItemLocation(serverID: serverID, path: RemotePath.root)
        case .item(let serverID, let path):
            return ItemLocation(serverID: serverID, path: path)
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

}
