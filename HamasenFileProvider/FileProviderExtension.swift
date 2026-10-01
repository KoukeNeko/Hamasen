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
        Task { await ActivityRecorder.shared.clearTransfers() }
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
            // Left at its single unit: the range call reports no bytes, and a
            // byte-scaled progress that never moves reads as a stalled
            // transfer, which is what gets one cancelled.
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
        let attempt = WriteAttempt()

        if contentType.conforms(to: .symbolicLink) {
            // No protocol here can create a link, and an empty file in its
            // place would be a lie. The system downloads an excluded item and
            // then asks for its deletion, which touches nothing on the server
            // since the identifier it names is not one of ours.
            Self.log.notice("createItem \(filename) excluded from sync: symbolic links cannot be created")
            completionHandler(nil, fields, false, NSFileProviderError(.excludedFromSync))
            return Self.answered()
        }

        let container = Self.containerLocation(of: itemTemplate.parentItemIdentifier)
        return performing(
            "createItem \(filename)",
            at: container,
            transferPath: container.map { RemotePath.join($0.path, filename) },
            kind: .write,
            retriesOnFreshSession: true
        ) { context in
            let service = context.service
            let serverID = context.location.serverID
            let newItemPath = RemotePath.join(context.location.path, filename)

            if let existing = try await Self.remoteItem(at: newItemPath, using: service) {
                let isSameKind = isDirectory ? existing.kind == .directory : existing.kind == .file
                // A repeat after a dropped session may find what its own
                // first attempt uploaded, which is not a collision.
                guard isSameKind, mayAlreadyExist || (context.isRetry && attempt.began) else {
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
                    // of it. Without contents it is dataless, so it is the
                    // server's file. With contents, the disk copy is the
                    // server's only if it was made from the version the
                    // server still has, or its bytes are the same — an
                    // equal size proves nothing, since an edit that keeps
                    // the length is ordinary. Anything else diverged, and
                    // neither side is dropped: the disk's bytes are kept
                    // beside the file as a conflict copy and the server's
                    // replace them on disk.
                    guard let url else {
                        return CreatedItem(item: existingItem, shouldFetchContent: false)
                    }
                    if let version = itemTemplate.itemVersion,
                       Self.hasContentVersion(version, serverID: serverID, existing) {
                        return CreatedItem(item: existingItem, shouldFetchContent: false)
                    }
                    if Self.fileSize(of: url) == existing.size,
                       try await Self.contentsMatch(url, existing, using: service, domain: domain) {
                        return CreatedItem(item: existingItem, shouldFetchContent: false)
                    }
                    context.progress.beginTransfer(byteCount: Self.fileSize(of: url), operation: .uploading)
                    try await Self.saveConflictCopy(
                        of: existing.name, inDirectory: context.location.path, serverID: serverID,
                        from: url, using: service, progress: context.progress)
                    return CreatedItem(item: existingItem, shouldFetchContent: true)
                }
            }

            if isDirectory {
                do {
                    attempt.begin()
                    try await service.createDirectory(at: newItemPath)
                } catch RemoteFileServiceError.alreadyExists {
                    // Created between the lookup and now, by whoever else
                    // is writing to the server; the directory is what was asked for.
                }
            } else if let url {
                context.progress.beginTransfer(byteCount: Self.fileSize(of: url), operation: .uploading)
                attempt.begin()
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
                attempt.begin()
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
        let source = Self.location(of: item.itemIdentifier)
        // A move to another server is recorded where the file ends up, so
        // the app's 在 Finder 中顯示 finds it there rather than where it was.
        var destination: ItemLocation?
        if changedFields.contains(.parentItemIdentifier), let source,
           let parent = Self.containerLocation(of: item.parentItemIdentifier), parent.serverID != source.serverID {
            let name = changedFields.contains(.filename) ? item.filename : RemotePath.name(of: source.path)
            destination = ItemLocation(serverID: parent.serverID, path: RemotePath.join(parent.path, name))
        }
        return performing(
            "modifyItem \(changedFields)",
            at: source,
            transferLocation: destination,
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
                    // The system may send the move together with an edit.
                    // What moves is the server's copy, so the edit has to
                    // follow it — or, when the server's copy changed since
                    // the edit's base, sit beside it as a conflict copy.
                    let editedContents = changedFields.contains(.contents) ? newContents : nil
                    var editConflicts = false
                    if editedContents != nil,
                       version.contentVersion != NSFileProviderItemVersion.beforeFirstSyncComponent {
                        let current = try await service.itemInfo(at: location.path)
                        editConflicts = !Self.hasContentVersion(version, serverID: serverID, current)
                    }
                    do {
                        var moved = try await Self.moveAcrossServers(
                            from: location, using: service, to: parent, named: name,
                            registry: registry, domain: domain, progress: context.progress)
                        guard let editedContents else {
                            return ModifiedItem(item: moved, shouldFetchContent: false)
                        }
                        let destinationService = try await Self.onDestination {
                            try await registry.service(for: parent.serverID)
                        }
                        let destinationPath = RemotePath.join(parent.path, name)
                        if editConflicts {
                            try await Self.onDestination {
                                try await Self.saveConflictCopy(
                                    of: name, inDirectory: parent.path, serverID: parent.serverID,
                                    from: editedContents, using: destinationService, progress: context.progress)
                            }
                            return ModifiedItem(item: moved, shouldFetchContent: true)
                        }
                        try await Self.onDestination {
                            try await destinationService.uploadFile(from: editedContents, to: destinationPath)
                        }
                        moved = RemoteFileItem(
                            serverID: parent.serverID,
                            remoteItem: try await Self.onDestination {
                                try await destinationService.itemInfo(at: destinationPath)
                            })
                        return ModifiedItem(item: moved, shouldFetchContent: false)
                    } catch is DestinationUnreachable {
                        // The server that could not be reached is the
                        // destination; the operation runs under the source's
                        // name, and a probe for that one would find it fine.
                        await registry.reportUnreachable(parent.serverID)
                        throw NSFileProviderError(.serverUnreachable)
                    }
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
        transferPath: String? = nil,
        transferLocation: ItemLocation? = nil,
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
            // Listed in the app's transfers if the work turns out to move
            // bytes; metadata calls never rescale the progress and never
            // appear.
            let watch = TransferWatch(
                progress: progress, serverID: transferLocation?.serverID ?? location.serverID,
                path: transferLocation?.path ?? transferPath ?? location.path)

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
                watch.finish(failure: nil)
                answer(.success(value))
                await registry.reportReachable(location.serverID)
                await ActivityRecorder.shared.recordHealth(ServerHealth(state: .reachable), for: location.serverID)
            case .failure(let error):
                if error is CancellationError || Task.isCancelled {
                    Self.log.debug("\(operation) \(location.path) cancelled")
                    watch.finish(failure: nil)
                    answer(.failure(CocoaError(.userCancelled)))
                    return
                }
                watch.finish(failure: error.localizedDescription)
                if let health = FileProviderErrorMapper.health(after: error) {
                    await ActivityRecorder.shared.recordHealth(health, for: location.serverID)
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

    /// Whether the file on disk holds the same bytes as the one on the
    /// server. The only way to know is to read both; the server's copy is
    /// fetched to the temporary directory and removed again.
    private static func contentsMatch(
        _ localURL: URL, _ remoteItem: RemoteItem, using service: any RemoteFileService,
        domain: NSFileProviderDomain
    ) async throws -> Bool {
        let remoteURL = try makeTemporaryFileURL(for: domain)
        defer { try? FileManager.default.removeItem(at: remoteURL) }
        try await service.downloadFile(at: remoteItem.path, to: remoteURL)
        return FileManager.default.contentsEqual(atPath: localURL.path, andPath: remoteURL.path)
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
        await ActivityRecorder.shared.recordConflict(ConflictRecord(
            serverID: serverID, path: RemotePath.join(directory, name), copyName: RemotePath.name(of: copyPath)))

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

    /// What a cross-server copy took from the source, so the source can be
    /// checked against it before it is deleted.
    private struct CopiedTree {
        /// Source path of each file to the content version that was copied.
        var files: [String: String] = [:]
        /// Source path of each directory to the names it held when listed.
        var directories: [String: Set<String>] = [:]
        /// Destination files this copy wrote, with the version each had once
        /// written (nil when it could not be read back), in creation order.
        var createdFiles: [(path: String, version: String?)] = []
        /// Destination folders this copy created, in creation order.
        var createdDirectories: [String] = []
    }

    /// Whether a creation got as far as writing to the server. A repeat
    /// after a dropped session may find what its first attempt wrote, which
    /// is not a collision — but only if that attempt wrote anything; a file
    /// someone else created meanwhile is.
    private final class WriteAttempt: @unchecked Sendable {
        private let lock = NSLock()
        private var hasBegun = false

        var began: Bool { lock.withLock { hasBegun } }

        func begin() {
            lock.withLock { hasBegun = true }
        }
    }

    /// The source changed while it was being copied. Deleting it would lose
    /// the change, so the move is undone and left for the system to retry.
    private struct SourceChangedDuringMove: Error {}

    /// Moves an item to a folder on another server. No protocol can do that
    /// in one step, so the item is copied and the original deleted once the
    /// copy is complete and the original is confirmed not to have changed
    /// meanwhile; a failed copy is removed again and leaves the original
    /// alone.
    private static func moveAcrossServers(
        from source: ItemLocation,
        using sourceService: any RemoteFileService,
        to parent: ItemLocation,
        named name: String,
        registry: ConnectionRegistry,
        domain: NSFileProviderDomain,
        progress: Progress
    ) async throws -> RemoteFileItem {
        let destinationService = try await onDestination { try await registry.service(for: parent.serverID) }
        let sourceInfo = try await sourceService.itemInfo(at: source.path)
        // The lookup follows links; whether the item itself is one only its
        // directory's own listing says.
        let sourceEntry = try await sourceService
            .listDirectoryWithoutFollowingLinks(at: RemotePath.parent(of: source.path))
            .first { $0.name == RemotePath.name(of: source.path) }
        if sourceEntry?.kind == .symlink { throw CocoaError(.featureUnsupported) }
        let destinationPath = RemotePath.join(parent.path, name)
        if let existing = try await onDestination({
            try await remoteItem(at: destinationPath, using: destinationService)
        }) {
            throw collision(with: existing, serverID: parent.serverID)
        }

        var copied = CopiedTree()
        var detached: String?
        do {
            if sourceInfo.isDirectory {
                progress.totalUnitCount = 1
                progress.completedUnitCount = 0
                try await copyDirectory(
                    from: source.path, using: sourceService,
                    to: destinationPath, using: destinationService,
                    domain: domain, progress: progress, copied: &copied)
            } else {
                // Every byte moves twice, down and then up. The activity
                // record halves it again (`TransferWatch`).
                progress.beginTransfer(byteCount: sourceInfo.size * 2, operation: .copying)
                let version = try await copyFile(
                    sourceInfo, using: sourceService,
                    to: destinationPath, using: destinationService,
                    domain: domain, byteProgress: progress)
                copied.createdFiles.append((destinationPath, version))
                copied.files[sourceInfo.path] = sourceInfo.contentVersionToken
            }
            // The copy took time, and the source may have moved on. It is
            // first moved out of everyone's way, to a name of its own, and
            // checked there: a write to the old path after that lands beside
            // it rather than in what is about to be deleted, and anything
            // that changed before is found by the check.
            let staging = RemotePath.temporaryUploadPath(for: source.path)
            try await sourceService.moveItem(from: source.path, to: staging)
            detached = staging
            guard try await isUnchanged(copied, on: sourceService, at: staging, originallyAt: source.path) else {
                throw SourceChangedDuringMove()
            }
        } catch {
            // Detached from cancellation, or the cleanup of a cancelled copy
            // would be cancelled itself.
            let copiedSoFar = copied
            let detachedSource = detached
            await Task {
                if let detachedSource {
                    do {
                        try await sourceService.moveItem(from: detachedSource, to: source.path)
                    } catch {
                        Self.log.error(
                            "A move could not put its source back: \(source.path) is at \(detachedSource): "
                            + "\(error.localizedDescription)")
                    }
                }
                await rollBack(copiedSoFar, on: destinationService)
            }.value
            throw error
        }

        if let detached {
            if sourceInfo.isDirectory {
                try await sourceService.deleteDirectory(at: detached)
            } else {
                try await sourceService.deleteFile(at: detached)
            }
        }
        return RemoteFileItem(
            serverID: parent.serverID,
            remoteItem: try await onDestination { try await destinationService.itemInfo(at: destinationPath) })
    }

    /// A connection failure on the destination side of a move, kept apart
    /// from the source's so the right server is probed.
    private struct DestinationUnreachable: Error {
        let underlying: Error
    }

    private static func onDestination<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch where FileProviderErrorMapper.isConnectionFailure(error) {
            throw DestinationUnreachable(underlying: error)
        }
    }

    /// Whether the source still holds exactly what was copied from it: the
    /// same names in every directory, the same content version on every
    /// file.
    ///
    /// Asked of the source after it was moved from `original` to `root`,
    /// which is where it is looked for; the record is by original path.
    private static func isUnchanged(
        _ copied: CopiedTree, on service: any RemoteFileService, at root: String, originallyAt original: String
    ) async throws -> Bool {
        func relocated(_ path: String) -> String { root + path.dropFirst(original.count) }
        func originalPath(_ path: String) -> String { original + path.dropFirst(root.count) }

        guard !copied.directories.isEmpty else {
            guard let (path, token) = copied.files.first else { return true }
            return try await service.itemInfo(at: relocated(path)).contentVersionToken == token
        }
        for (path, names) in copied.directories {
            let listing = try await service.listDirectoryWithoutFollowingLinks(at: relocated(path))
            guard Set(listing.map(\.name)) == names else { return false }
            for item in listing where item.kind == .file {
                guard copied.files[originalPath(item.path)] == item.contentVersionToken else { return false }
            }
        }
        return true
    }

    /// Removes what a failed move copied, and only that.
    ///
    /// Someone may have written to the destination since the copy: a file
    /// that is no longer the version the copy wrote is theirs and stays, and
    /// a folder that is not empty once this copy's files are gone holds
    /// something of theirs and stays too. No protocol here can delete on a
    /// condition, so a write landing between the check and the delete can
    /// still be lost; the check narrows that to a moment.
    private static func rollBack(_ copied: CopiedTree, on service: any RemoteFileService) async {
        var kept = 0
        for file in copied.createdFiles.reversed() {
            guard let version = file.version,
                  let current = try? await service.itemInfo(at: file.path),
                  current.contentVersionToken == version
            else {
                kept += 1
                continue
            }
            try? await service.deleteFile(at: file.path)
        }
        for directory in copied.createdDirectories.reversed() {
            guard (try? await service.listDirectoryWithoutFollowingLinks(at: directory))?.isEmpty == true else {
                kept += 1
                continue
            }
            try? await service.deleteDirectory(at: directory)
        }
        if kept > 0 {
            Self.log.notice("Undoing a move left \(kept) items that had changed since they were copied")
        }
    }

    /// Copies one file through a temporary file. With `byteProgress`, its
    /// units are bytes over two passes: the download first, the upload after.
    /// Returns the copy's content version as the destination reports it, so a
    /// rollback can tell it from a later write; nil when it cannot be read.
    private static func copyFile(
        _ item: RemoteItem,
        using sourceService: any RemoteFileService,
        to destinationPath: String,
        using destinationService: any RemoteFileService,
        domain: NSFileProviderDomain,
        byteProgress: Progress?
    ) async throws -> String? {
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

        // Uploaded under a name of its own and then renamed into place,
        // because an upload overwrites: a file someone created at the
        // destination since it was checked would otherwise be replaced, and
        // a rollback would then delete it. The rename refuses an existing
        // name — on FTP, as far as the server does.
        let staging = RemotePath.temporaryUploadPath(for: destinationPath)
        do {
            try await onDestination {
                try await destinationService.uploadFile(from: temporaryURL, to: staging, progress: uploaded)
                try await destinationService.moveItem(from: staging, to: destinationPath)
            }
        } catch {
            try? await destinationService.deleteFile(at: staging)
            throw error
        }
        return try? await destinationService.itemInfo(at: destinationPath).contentVersionToken
    }

    /// Copies a tree. Units are entries, added as directories are listed,
    /// so a long copy keeps moving the progress the system watches.
    private static func copyDirectory(
        from sourcePath: String,
        using sourceService: any RemoteFileService,
        to destinationPath: String,
        using destinationService: any RemoteFileService,
        domain: NSFileProviderDomain,
        progress: Progress,
        copied: inout CopiedTree
    ) async throws {
        try await onDestination { try await destinationService.createDirectory(at: destinationPath) }
        copied.createdDirectories.append(destinationPath)
        // Links as links: followed, a link to a directory would be copied as
        // the directory, and one to an ancestor would never end.
        let children = try await sourceService.listDirectoryWithoutFollowingLinks(at: sourcePath)
        copied.directories[sourcePath] = Set(children.map(\.name))
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
                    domain: domain, progress: progress, copied: &copied)
            case .file:
                let version = try await copyFile(
                    child, using: sourceService,
                    to: childDestination, using: destinationService,
                    domain: domain, byteProgress: nil)
                copied.createdFiles.append((childDestination, version))
                copied.files[child.path] = child.contentVersionToken
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
