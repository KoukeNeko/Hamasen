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

    /// The same registry, reachable from the search conformance in its own
    /// file. Private would mean a second registry and a second set of
    /// connections for every query.
    var searchRegistry: ConnectionRegistry { registry }

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
        if #available(macOS 26, *) {
            Self.log.notice(
                "Extension started for \(domain.identifier.rawValue); "
                + "supportsStringSearchRequest=\(domain.supportsStringSearchRequest) "
                + "userEnabled=\(domain.userEnabled) hidden=\(domain.isHidden) "
                + "testingModes=\(domain.testingModes.rawValue) "
                + "supportsKnownFolders=\(domain.supportedKnownFolders.rawValue) "
                + "replicatedKnownFolders=\(domain.replicatedKnownFolders.rawValue) "
                + "backingStoreIdentity=\(domain.backingStoreIdentity.map { String(decoding: $0, as: UTF8.self) } ?? "nil")")
        }
    }

    static let log = HamasenLog(category: "extension")

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
        if identifier == .trashContainer {
            completionHandler(TrashItem(), nil)
            return Self.answered()
        }
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
            return performing("item", at: Self.location(of: identifier), retriesOnFreshSession: true) { context in
                RemoteFileItem(
                    serverID: context.location.serverID,
                    remoteItem: try await context.service.itemInfo(at: context.location.path)
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
        return performing(
            "fetch", at: Self.location(of: itemIdentifier), retriesOnFreshSession: true
        ) { context in
            let location = context.location
            Self.log.notice("Fetching \(location.path) on \(location.serverID)")
            let info = try await context.service.itemInfo(at: location.path)
            let (localURL, latest) = try await Self.downloadUnchanged(
                info, using: context.service, progress: context.progress, domain: domain)
            return (localURL, RemoteFileItem(serverID: location.serverID, remoteItem: latest))
        } answer: { result in
            switch result {
            case .success(let (localURL, item)): completionHandler(localURL, item, nil)
            case .failure(let error): completionHandler(nil, nil, error)
            }
        }
    }

    /// The file changed on the server while it was being downloaded, twice.
    /// Handing back the bytes under either version would pair content with
    /// the wrong version, so the fetch fails and is retried as a whole.
    private struct ContentChangedDuringFetch: Error {}

    /// Downloads a file and returns it with the item that matches the bytes.
    ///
    /// The lookup that precedes a download says nothing about what the
    /// download then delivers, so the item is read again afterwards and a
    /// download that raced an edit is done once more. The temporary file is
    /// removed on every path that does not hand it to the system.
    private static func downloadUnchanged(
        _ info: RemoteItem,
        using service: any RemoteFileService,
        progress: Progress,
        domain: NSFileProviderDomain
    ) async throws -> (URL, RemoteItem) {
        var expected = info
        var mayRepeat = true
        while true {
            let localURL = try makeTemporaryFileURL(for: domain)
            do {
                progress.beginTransfer(byteCount: expected.size, operation: .downloading)
                try await service.downloadFile(at: expected.path, to: localURL, progress: progress.byteReporter)
                let latest = try await service.itemInfo(at: expected.path)
                if latest.contentVersionToken == expected.contentVersionToken {
                    return (localURL, latest)
                }
                expected = latest
            } catch {
                try? FileManager.default.removeItem(at: localURL)
                throw error
            }
            try? FileManager.default.removeItem(at: localURL)
            guard mayRepeat else { throw ContentChangedDuringFetch() }
            mayRepeat = false
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
        return performing(
            "fetch", at: Self.location(of: itemIdentifier), retriesOnFreshSession: true
        ) { context in
            let service = context.service
            let location = context.location
            let info = try await service.itemInfo(at: location.path)

            // The system discards any other version than the one it asked
            // for under strict versioning, so bytes of a newer one are worse
            // than an error.
            if options.contains(.strictVersioning),
               !Self.hasContentVersion(requestedVersion, serverID: location.serverID, info) {
                throw NSFileProviderError(.versionNoLongerAvailable)
            }

            // A server that does not report a size leaves no way to align a
            // range; fetching the whole item is the only way to avoid handing
            // back an empty file that looks correctly versioned.
            guard info.size > 0 else {
                let (localURL, latest) = try await Self.downloadUnchanged(
                    info, using: service, progress: context.progress, domain: domain)
                let byteCount = (try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return FetchedRange(
                    localURL: localURL,
                    item: RemoteFileItem(serverID: location.serverID, remoteItem: latest),
                    range: NSRange(location: 0, length: byteCount)
                )
            }

            let range = ByteRangeAlignment.align(
                offset: Int64(requestedRange.location),
                length: requestedRange.length,
                alignment: alignment,
                fileSize: info.size
            )
            context.progress.beginTransfer(byteCount: Int64(range.length), operation: .downloading)
            let contents = try await service.downloadRange(
                at: location.path,
                offset: range.offset,
                length: range.length
            )
            try Task.checkCancellation()

            let localURL = try Self.makeTemporaryFileURL(for: domain)
            do {
                try Self.write(contents, at: range.offset, to: localURL)
            } catch {
                try? FileManager.default.removeItem(at: localURL)
                throw error
            }
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

    // MARK: - Create

    /// What a creation hands back: nil when the system offered something that
    /// could not be matched to anything on the server.
    private struct CreatedItem {
        let item: NSFileProviderItem?
        let shouldFetchContent: Bool
    }

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let domain = domain
        let filename = itemTemplate.filename
        let contentType = itemTemplate.contentType ?? .data
        // Packages such as .app and .rtfd are directories on the server too;
        // the system creates their children one by one.
        let isDirectory = contentType.conforms(to: .directory)
        let mayAlreadyExist = options.contains(.mayAlreadyExist)

        if contentType.conforms(to: .symbolicLink) {
            // No protocol here can create a link, and an empty file in its
            // place would be a lie. The system downloads an excluded item and
            // then asks for its deletion, which touches nothing on the server
            // since the identifier it names is not one of ours.
            Self.log.notice("createItem \(filename) excluded from sync: symbolic links cannot be created")
            completionHandler(nil, fields, false, NSFileProviderError(.excludedFromSync))
            return Self.answered()
        }

        return performing(
            "createItem \(filename)",
            at: Self.containerLocation(of: itemTemplate.parentItemIdentifier),
            kind: .write,
            retriesOnFreshSession: true
        ) { context in
            let service = context.service
            let serverID = context.location.serverID
            let newItemPath = RemotePath.join(context.location.path, filename)

            if let existing = try await Self.remoteItem(at: newItemPath, using: service) {
                let isSameKind = isDirectory ? existing.kind == .directory : existing.kind == .file
                // A repeat after a dropped session finds what its own first
                // attempt uploaded, which is not a collision.
                guard isSameKind, mayAlreadyExist || context.isRetry else {
                    throw Self.collision(with: existing, serverID: serverID)
                }
                let existingItem = RemoteFileItem(serverID: serverID, remoteItem: existing)
                if isDirectory {
                    // Directories merge: the system re-creates the children
                    // against this one.
                    return CreatedItem(item: existingItem, shouldFetchContent: false)
                }
                if mayAlreadyExist {
                    // The system found the file on disk after losing track
                    // of it. Without contents (it is dataless) or with the
                    // same size, it is the server's file. A different size
                    // means the two diverged; neither side is dropped: the
                    // disk's bytes are kept beside it as a conflict copy and
                    // the server's replace them on disk.
                    guard let url, Self.fileSize(of: url) != existing.size else {
                        return CreatedItem(item: existingItem, shouldFetchContent: false)
                    }
                    try await Self.saveConflictCopy(
                        of: existing.name, inDirectory: context.location.path, serverID: serverID,
                        from: url, using: service, progress: context.progress)
                    return CreatedItem(item: existingItem, shouldFetchContent: true)
                }
            }

            if isDirectory {
                do {
                    try await service.createDirectory(at: newItemPath)
                } catch RemoteFileServiceError.alreadyExists {
                    // Created between the lookup and now, by whoever else
                    // is writing to the server; the directory is what was asked for.
                }
            } else if let url {
                context.progress.beginTransfer(byteCount: Self.fileSize(of: url), operation: .uploading)
                try await service.uploadFile(from: url, to: newItemPath, progress: context.progress.byteReporter)
            } else if mayAlreadyExist {
                // Nothing on the server to match and no contents to create
                // it from: the header asks for no item in that case.
                return CreatedItem(item: nil, shouldFetchContent: false)
            } else {
                // A file with no contents yet (e.g. Finder creating a
                // placeholder): create it empty on the server.
                let emptyFileURL = try Self.makeTemporaryFileURL(for: domain)
                try Data().write(to: emptyFileURL)
                defer { try? FileManager.default.removeItem(at: emptyFileURL) }
                try await service.uploadFile(from: emptyFileURL, to: newItemPath)
            }
            return CreatedItem(
                item: RemoteFileItem(serverID: serverID, remoteItem: try await service.itemInfo(at: newItemPath)),
                shouldFetchContent: false
            )
        } answer: { result in
            switch result {
            case .success(let created): completionHandler(created.item, [], created.shouldFetchContent, nil)
            case .failure(let error): completionHandler(nil, fields, false, error)
            }
        }
    }

    // MARK: - Modify

    private struct ModifiedItem {
        let item: NSFileProviderItem
        let shouldFetchContent: Bool
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
        case .item:
            if changedFields.isDisjoint(with: Self.modifiableFields) {
                // Only fields this provider cannot store, typically Finder
                // stamping a date. Returning the fields as still pending,
                // unchanged, is how the system is told they are unsupported,
                // and nothing on the server needs to be read for that.
                completionHandler(item, changedFields, false, nil)
                return Self.answered()
            }
        case nil:
            break
        }

        let registry = registry
        let domain = domain
        return performing(
            "modifyItem \(changedFields)",
            at: Self.location(of: item.itemIdentifier),
            kind: .write
        ) { context in
            let service = context.service
            let location = context.location
            let serverID = location.serverID

            let isRenamed = changedFields.contains(.filename)
            let isReparented = changedFields.contains(.parentItemIdentifier)
            var newParentPath = RemotePath.parent(of: location.path)
            if isReparented {
                guard let parent = Self.containerLocation(of: item.parentItemIdentifier) else {
                    // The domain root accepts no items, and there is nothing
                    // to move to.
                    throw NSFileProviderError(.noSuchItem)
                }
                guard parent.serverID == serverID else {
                    // Not a rename: `.noSuchItem` here would make the system
                    // delete the item from disk, so the move is done as a
                    // copy to the other server followed by a delete.
                    let name = isRenamed ? item.filename : RemotePath.name(of: location.path)
                    let moved = try await Self.moveAcrossServers(
                        from: location, using: service, to: parent, named: name,
                        registry: registry, domain: domain, progress: context.progress)
                    return ModifiedItem(item: moved, shouldFetchContent: false)
                }
                newParentPath = parent.path
            }
            let newName = isRenamed ? item.filename : RemotePath.name(of: location.path)
            let destinationPath = RemotePath.join(newParentPath, newName)

            var contentsToUpload = changedFields.contains(.contents) ? newContents : nil
            var shouldFetchContent = false
            var isGone = false
            if let localContents = contentsToUpload {
                context.progress.beginTransfer(byteCount: Self.fileSize(of: localContents), operation: .uploading)
                // The base version is the last one the disk and the server
                // agreed on. If the server has moved on, uploading would
                // silently replace someone else's edit.
                if version.contentVersion != NSFileProviderItemVersion.beforeFirstSyncComponent {
                    do {
                        let current = try await service.itemInfo(at: location.path)
                        if !Self.hasContentVersion(version, serverID: serverID, current) {
                            try await Self.saveConflictCopy(
                                of: newName, inDirectory: newParentPath, serverID: serverID,
                                from: localContents, using: service, progress: context.progress)
                            // The server's version stays the item's, and its
                            // version differing from the base one is what
                            // makes the system fetch it over the disk copy.
                            contentsToUpload = nil
                            shouldFetchContent = true
                        }
                    } catch RemoteFileServiceError.itemNotFound {
                        // Deleted on the server while being edited here. The
                        // edit is all that is left of the file, so it is
                        // uploaded again rather than dropped.
                        isGone = true
                    }
                }
            }

            var effectivePath = location.path
            if destinationPath != location.path, !isGone {
                try await service.moveItem(from: location.path, to: destinationPath)
                effectivePath = destinationPath
            } else if isGone {
                effectivePath = destinationPath
            }

            if let contentsToUpload {
                try await service.uploadFile(
                    from: contentsToUpload, to: effectivePath, progress: context.progress.byteReporter)
            }

            return ModifiedItem(
                item: RemoteFileItem(
                    serverID: serverID, remoteItem: try await service.itemInfo(at: effectivePath)),
                shouldFetchContent: shouldFetchContent
            )
        } answer: { result in
            switch result {
            case .success(let modified):
                completionHandler(
                    modified.item, changedFields.subtracting(Self.modifiableFields),
                    modified.shouldFetchContent, nil)
            case .failure(let error):
                completionHandler(nil, changedFields, false, error)
            }
        }
    }

    // MARK: - Delete

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        // An identifier that is not ours names an item this provider never
        // held (the system asks after excluding one from sync). The header
        // says an unknown item is already deleted.
        if ItemIdentifierMapper.entity(for: identifier) == nil {
            completionHandler(nil)
            return Self.answered()
        }

        // Server folders and the root are managed from the app, so anything
        // that is not an item on a server resolves to no location.
        return performing(
            "deleteItem", at: Self.location(of: identifier), kind: .write
        ) { context in
            let service = context.service
            let serverID = context.location.serverID
            let path = context.location.path

            let info: RemoteItem
            do {
                info = try await service.itemInfo(at: path)
            } catch RemoteFileServiceError.itemNotFound {
                return
            }

            // An edit made on the server since the version being deleted was
            // seen is not this deletion's to discard. Directories change
            // whenever a child does, so only files carry the check.
            if info.kind != .directory,
               version.contentVersion != NSFileProviderItemVersion.beforeFirstSyncComponent,
               !Self.hasContentVersion(version, serverID: serverID, info) {
                throw NSError.fileProviderErrorForRejectedDeletion(
                    of: RemoteFileItem(serverID: serverID, remoteItem: info))
            }

            do {
                if info.isDirectory {
                    if !options.contains(.recursive), !(try await service.listDirectory(at: path)).isEmpty {
                        throw NSFileProviderError(.directoryNotEmpty)
                    }
                    // Recursive by contract: WebDAV does it in one request,
                    // SFTP walks the tree itself.
                    try await service.deleteDirectory(at: path)
                } else {
                    try await service.deleteFile(at: path)
                }
            } catch RemoteFileServiceError.itemNotFound {
                // Removed by someone else since the lookup: the goal is met.
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
        case .rootContainer:
            return ServerListEnumerator()
        case .workingSet:
            // What the replica holds and what Spotlight indexes. The server
            // folders, as the root has, and then every directory beneath
            // them that the settings allow.
            return WorkingSetEnumerator(registry: registry)
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

    /// What one operation is given to work with.
    struct WorkContext {
        let service: any RemoteFileService
        let location: ItemLocation
        /// The progress the system watches. Metadata calls leave it at its
        /// single unit; transfers rescale it to bytes.
        let progress: Progress
        /// True on the repeat after a dead session, when an earlier attempt
        /// may already have changed the server.
        let isRetry: Bool
    }

    /// Runs one server-side operation the way every entry point here runs
    /// one: on a progress the system can watch, against the connection for
    /// that item's server, answering exactly once and only ever with an
    /// error the system accepts.
    ///
    /// A session that died while idle is the most common failure, and it
    /// only shows on the first call that uses it. With
    /// `retriesOnFreshSession` the work is repeated once on a new connection
    /// before anything is reported, which is only for work that can safely
    /// run twice: reads, overwriting uploads, creations that tolerate the
    /// item already being there. Moves, renames and deletes are not.
    private func performing<Success>(
        _ operation: String,
        at location: ItemLocation?,
        kind: FileProviderErrorMapper.Operation = .read,
        retriesOnFreshSession: Bool = false,
        work: @escaping (WorkContext) async throws -> Success,
        answer: @escaping (Result<Success, Error>) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let registry = registry
        let task = Task {
            defer { progress.completedUnitCount = progress.totalUnitCount }
            guard let location else {
                // Not an error worth a stack trace, but the system turns it
                // into a permanent failure, so it is worth knowing about.
                Self.log.notice("\(operation) refused: not an item on a server")
                answer(.failure(NSFileProviderError(.noSuchItem)))
                return
            }
            Self.log.debug("\(operation) \(location.path) on \(location.serverID)")

            let outcome: Result<Success, Error>
            do {
                var lease = try await registry.lease(for: location.serverID)
                do {
                    let context = WorkContext(
                        service: lease.service, location: location, progress: progress, isRetry: false)
                    outcome = .success(try await work(context))
                } catch where retriesOnFreshSession && FileProviderErrorMapper.isConnectionFailure(error) {
                    Self.log.notice("\(operation) \(location.path) lost its session; retrying on a new connection")
                    await registry.discard(lease)
                    lease = try await registry.lease(for: location.serverID)
                    let context = WorkContext(
                        service: lease.service, location: location, progress: progress, isRetry: true)
                    outcome = .success(try await work(context))
                }
            } catch {
                outcome = .failure(error)
            }

            switch outcome {
            case .success(let value):
                answer(.success(value))
                await registry.reportReachable(location.serverID)
            case .failure(let error):
                if error is CancellationError || Task.isCancelled {
                    Self.log.debug("\(operation) \(location.path) cancelled")
                    answer(.failure(CocoaError(.userCancelled)))
                    return
                }
                // The system retries a few times and then gives up on the
                // item for good, so a failure here is the last chance to
                // learn why a change never reached the server.
                Self.log.error("\(operation) \(location.path) on \(location.serverID) failed: \(error.localizedDescription)")
                answer(.failure(FileProviderErrorMapper.map(error, during: kind)))
                if FileProviderErrorMapper.isConnectionFailure(error) {
                    await registry.reportUnreachable(location.serverID)
                }
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

    private static func fileSize(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    /// The item at a path, or nil when nothing is there.
    private static func remoteItem(
        at path: String, using service: any RemoteFileService
    ) async throws -> RemoteItem? {
        do {
            return try await service.itemInfo(at: path)
        } catch RemoteFileServiceError.itemNotFound {
            return nil
        }
    }

    /// Whether the server's item still has the content the system's version
    /// describes. Goes through the item's own version so the two can never
    /// be derived differently.
    private static func hasContentVersion(
        _ version: NSFileProviderItemVersion, serverID: UUID, _ remoteItem: RemoteItem
    ) -> Bool {
        let current = RemoteFileItem(serverID: serverID, remoteItem: remoteItem, isPinned: false)
            .itemVersion.contentVersion
        return version.contentVersion == current
            || version.contentVersion == legacyContentVersion(of: remoteItem)
    }

    /// The content version earlier releases gave the same item: size and the
    /// modification time as a full-precision double.
    ///
    /// A file downloaded before the version format changed keeps that version
    /// on disk until its folder is listed again. Compared only against the
    /// new format, the first edit or deletion of every such file would read
    /// as a conflict with the server and fork a copy of an unchanged file.
    private static func legacyContentVersion(of remoteItem: RemoteItem) -> Data {
        let modificationEpoch = remoteItem.modificationDate?.timeIntervalSince1970 ?? 0
        return Data("\(remoteItem.size)-\(modificationEpoch)".utf8)
    }

    /// The error that has the system rename one of two items claiming the
    /// same name, and then create this one again.
    private static func collision(with existing: RemoteItem, serverID: UUID) -> Error {
        NSError.fileProviderErrorForCollision(with: RemoteFileItem(serverID: serverID, remoteItem: existing))
    }

    // MARK: Conflict copies

    /// Uploads local contents beside the file they conflict with, so neither
    /// the local edit nor the server's version is lost, and tells the system
    /// the directory has a new item.
    private static func saveConflictCopy(
        of name: String,
        inDirectory directory: String,
        serverID: UUID,
        from localURL: URL,
        using service: any RemoteFileService,
        progress: Progress
    ) async throws {
        let now = Date()
        var attempt = 0
        var copyPath: String
        repeat {
            copyPath = RemotePath.join(directory, ConflictCopyName.make(for: name, at: now, attempt: attempt))
            attempt += 1
        } while try await remoteItem(at: copyPath, using: service) != nil

        try await service.uploadFile(from: localURL, to: copyPath, progress: progress.byteReporter)
        Self.log.notice("Kept a conflicting edit as \(copyPath) on \(serverID)")

        do {
            try DirectoryRefreshQueue().enqueue([.init(serverID: serverID, path: directory)])
            try await FinderDomain.signalWorkingSet()
        } catch {
            // The copy exists either way; the system sees it the next time
            // the directory is listed.
            Self.log.error("Could not announce the conflict copy in \(directory): \(error.localizedDescription)")
        }
    }

    // MARK: Moving between servers

    /// Moves an item to a folder on another server. No protocol can do that
    /// in one step, so the item is copied and the original deleted once the
    /// copy is complete; a failed copy is removed again and leaves the
    /// original alone.
    private static func moveAcrossServers(
        from source: ItemLocation,
        using sourceService: any RemoteFileService,
        to parent: ItemLocation,
        named name: String,
        registry: ConnectionRegistry,
        domain: NSFileProviderDomain,
        progress: Progress
    ) async throws -> RemoteFileItem {
        let destinationService = try await registry.service(for: parent.serverID)
        let sourceInfo = try await sourceService.itemInfo(at: source.path)
        let destinationPath = RemotePath.join(parent.path, name)
        if let existing = try await remoteItem(at: destinationPath, using: destinationService) {
            throw collision(with: existing, serverID: parent.serverID)
        }

        do {
            if sourceInfo.isDirectory {
                progress.totalUnitCount = 1
                progress.completedUnitCount = 0
                try await copyDirectory(
                    from: source.path, using: sourceService,
                    to: destinationPath, using: destinationService,
                    domain: domain, progress: progress)
            } else {
                // Every byte moves twice, down and then up.
                progress.beginTransfer(byteCount: sourceInfo.size * 2, operation: .copying)
                try await copyFile(
                    sourceInfo, using: sourceService,
                    to: destinationPath, using: destinationService,
                    domain: domain, byteProgress: progress)
            }
        } catch {
            // Detached from cancellation, or the cleanup of a cancelled
            // copy would be cancelled itself.
            await Task {
                if sourceInfo.isDirectory {
                    try? await destinationService.deleteDirectory(at: destinationPath)
                } else {
                    try? await destinationService.deleteFile(at: destinationPath)
                }
            }.value
            throw error
        }

        if sourceInfo.isDirectory {
            try await sourceService.deleteDirectory(at: source.path)
        } else {
            try await sourceService.deleteFile(at: source.path)
        }
        return RemoteFileItem(
            serverID: parent.serverID,
            remoteItem: try await destinationService.itemInfo(at: destinationPath))
    }

    /// Copies one file through a temporary file. With `byteProgress`, its
    /// units are bytes over two passes: the download first, the upload after.
    private static func copyFile(
        _ item: RemoteItem,
        using sourceService: any RemoteFileService,
        to destinationPath: String,
        using destinationService: any RemoteFileService,
        domain: NSFileProviderDomain,
        byteProgress: Progress?
    ) async throws {
        let temporaryURL = try makeTemporaryFileURL(for: domain)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let size = item.size
        let downloaded: TransferProgress? = byteProgress.map { progress in
            { @Sendable bytes in progress.completedUnitCount = min(bytes, progress.totalUnitCount) }
        }
        let uploaded: TransferProgress? = byteProgress.map { progress in
            { @Sendable bytes in progress.completedUnitCount = min(size + bytes, progress.totalUnitCount) }
        }
        try await sourceService.downloadFile(at: item.path, to: temporaryURL, progress: downloaded)
        try await destinationService.uploadFile(from: temporaryURL, to: destinationPath, progress: uploaded)
    }

    /// Copies a tree. Units are entries, added as directories are listed,
    /// so a long copy keeps moving the progress the system watches.
    private static func copyDirectory(
        from sourcePath: String,
        using sourceService: any RemoteFileService,
        to destinationPath: String,
        using destinationService: any RemoteFileService,
        domain: NSFileProviderDomain,
        progress: Progress
    ) async throws {
        try await destinationService.createDirectory(at: destinationPath)
        let children = try await sourceService.listDirectory(at: sourcePath)
        progress.totalUnitCount += Int64(children.count)
        progress.completedUnitCount += 1

        for child in children {
            try Task.checkCancellation()
            let childDestination = RemotePath.join(destinationPath, child.name)
            switch child.kind {
            case .directory:
                try await copyDirectory(
                    from: child.path, using: sourceService,
                    to: childDestination, using: destinationService,
                    domain: domain, progress: progress)
            case .file:
                try await copyFile(
                    child, using: sourceService,
                    to: childDestination, using: destinationService,
                    domain: domain, byteProgress: nil)
                progress.completedUnitCount += 1
            case .symlink:
                // No protocol can create one on the other side, and copying
                // what it points at would silently change what it is. The
                // original is deleted afterwards, so it must not be skipped.
                throw CocoaError(.featureUnsupported)
            }
        }
    }
}

extension Progress {
    /// Rescales the progress to a transfer's bytes, so the system sees it
    /// advance with the data and does not cancel it as stalled. An empty file
    /// still gets one unit, or the progress would have no extent to fill.
    fileprivate func beginTransfer(byteCount: Int64, operation: Progress.FileOperationKind) {
        kind = .file
        fileOperationKind = operation
        totalUnitCount = max(byteCount, 1)
        completedUnitCount = 0
    }

    /// Feeds a service's running byte total into this progress.
    fileprivate var byteReporter: TransferProgress {
        { [self] bytesTransferred in
            completedUnitCount = min(bytesTransferred, totalUnitCount)
        }
    }
}
