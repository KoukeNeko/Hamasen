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

import AppKit
import FileProvider
import Foundation
import HamasenCore

/// The Finder context-menu entries, run by the provider itself.
///
/// Finder builds this menu from the actions declared in this extension's
/// Info.plist (`NSExtensionFileProviderActions`) and evaluates their rules
/// against its own item index, so nothing here runs until the user picks an
/// entry — Google Drive and Synology Drive add their entries the same way.
/// None of the actions asks the user anything, so no UI extension is needed.
extension FileProviderExtension: NSFileProviderCustomAction {
    func performAction(
        identifier actionIdentifier: NSFileProviderExtensionActionIdentifier,
        onItemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        guard let action = FinderAction(rawValue: actionIdentifier.rawValue) else {
            completionHandler(CustomActionError.unknownAction(actionIdentifier.rawValue))
            progress.completedUnitCount = 1
            return progress
        }

        let task = Task {
            defer { progress.completedUnitCount = 1 }
            do {
                let afterCompletion = try await CustomActionRunner.run(action, on: itemIdentifiers, registry: searchRegistry)
                completionHandler(nil)
                await afterCompletion?()
            } catch is CancellationError {
                CustomActionRunner.log.notice("\(action.rawValue) cancelled by the system")
                completionHandler(CocoaError(.userCancelled))
            } catch {
                // Finder shows little or nothing for a failed action, so the
                // log is the only place the reason survives.
                CustomActionRunner.log.error("\(action.rawValue) failed: \(error.localizedDescription)")
                completionHandler(error)
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }
}

/// Executes one context-menu action on the selection Finder passed along.
enum CustomActionRunner {
    static let log = HamasenLog(category: "CustomActions")

    /// Work that must wait until the system has been told the action is
    /// done. Unmounting the last server hides the domain, which takes the
    /// location away from under the action still waiting on it; and asking
    /// the system to re-enumerate a folder while it is still waiting on the
    /// action never gets an answer.
    typealias AfterCompletion = () async -> Void

    static func run(
        _ action: FinderAction,
        on itemIdentifiers: [NSFileProviderItemIdentifier],
        registry: ConnectionRegistry
    ) async throws -> AfterCompletion? {
        // The system may cancel the Progress before the task gets scheduled;
        // nothing below is long enough to need a second check.
        try Task.checkCancellation()

        let entities = itemIdentifiers.compactMap(ItemIdentifierMapper.entity(for:))
        guard entities.count == itemIdentifiers.count, !entities.isEmpty else {
            throw CustomActionError.notAHamasenItem
        }

        switch action {
        case .copyRemotePath:
            let entity = try singleServerEntity(in: entities)
            try await copyRemotePath(of: entity)
            return nil
        case .copyLocalPath:
            guard itemIdentifiers.count == 1, let identifier = itemIdentifiers.first else {
                throw CustomActionError.notAHamasenItem
            }
            try await copyLocalPath(of: identifier)
            return nil
        case .refresh:
            try await refresh(entities, identifiers: itemIdentifiers)
            return nil
        case .unmountServer:
            let entity = try singleServerEntity(in: entities)
            guard case .serverRoot(let serverID) = entity else {
                throw CustomActionError.notAServerFolder
            }
            return try await unmountServer(serverID)
        case .freeLocalSpace:
            try await freeLocalSpace(of: entities)
            return nil
        case .keepOnMac:
            return try setPinned(true, on: entities)
        case .stopKeepingOnMac:
            return try setPinned(false, on: entities)
        case .copyURL:
            let entity = try singleServerEntity(in: entities)
            try await copyToPasteboard(try await url(of: entity, registry: registry).absoluteString)
            return nil
        case .openInBrowser:
            let entity = try singleServerEntity(in: entities)
            guard let serverID = entity.serverID,
                  let page = try await registry.service(for: serverID).browserURL(for: entity.path)
            else { throw CustomActionError.noWebPage }
            try await open(page)
            return nil
        case .openInTerminal:
            let entity = try singleServerEntity(in: entities)
            guard let serverID = entity.serverID else { throw CustomActionError.notAHamasenItem }
            try await open(try sshURL(for: ConnectionRegistry.config(for: serverID)))
            return nil
        case .showInHamasen:
            let entity = try singleServerEntity(in: entities)
            guard let serverID = entity.serverID else { throw CustomActionError.notAHamasenItem }
            try await open(AppLink.connection(serverID))
            return nil
        }
    }

    /// The address another client is given; a cloud drive, which has none,
    /// gives its web page instead, which takes asking its API.
    private static func url(of entity: ProviderEntity, registry: ConnectionRegistry) async throws -> URL {
        guard let serverID = entity.serverID else { throw CustomActionError.notAHamasenItem }
        if let address = RemoteItemAddress.url(of: entity.path, on: try ConnectionRegistry.config(for: serverID)) {
            return address
        }
        guard let page = try await registry.service(for: serverID).browserURL(for: entity.path) else {
            throw CustomActionError.noWebPage
        }
        return page
    }

    /// Terminal answers `ssh://` itself and signs in with the user's own
    /// keys and ~/.ssh/config. A URL cannot carry a command, so the session
    /// starts in the account's home rather than in the folder.
    private static func sshURL(for config: ServerConfig) throws -> URL {
        var components = URLComponents()
        components.scheme = "ssh"
        if !config.username.isEmpty { components.user = config.username }
        components.host = RemoteItemAddress.urlHost(for: config.host)
        if config.port != config.transferProtocol.defaultPort { components.port = config.port }
        guard config.transferProtocol == .sftp, let url = components.url else {
            throw CustomActionError.cannotOpen("ssh")
        }
        return url
    }

    /// Hands the URL to whichever app claims it: the browser, Terminal, or
    /// Hamasen itself for its own links.
    private static func open(_ url: URL) async throws {
        let didOpen = await MainActor.run { NSWorkspace.shared.open(url) }
        guard didOpen else { throw CustomActionError.cannotOpen(url.scheme ?? "") }
    }

    /// The activation rules restrict these actions to one item on a server;
    /// anything else reaching here means the rules and the code disagree.
    private static func singleServerEntity(in entities: [ProviderEntity]) throws -> ProviderEntity {
        guard entities.count == 1, let entity = entities.first, entity.serverID != nil else {
            throw CustomActionError.notAHamasenItem
        }
        return entity
    }

    /// Puts the address the item has *on the server* on the clipboard, which
    /// is what you need to reach it over ssh or in another client.
    private static func copyRemotePath(of entity: ProviderEntity) async throws {
        guard let serverID = entity.serverID else { throw CustomActionError.notAHamasenItem }
        let config = try ConnectionRegistry.config(for: serverID)
        let remotePath = RemotePath.resolve(entity.path, against: config.remotePath)

        try await copyToPasteboard("\(config.username)@\(config.host):\(remotePath)")
    }

    /// Puts the item's path on this Mac on the clipboard — what a terminal or
    /// a script needs, as opposed to the address it has on the server.
    ///
    /// Only the system knows where a domain is mounted (the folder is named
    /// after the domain and gains a suffix when an older one is still around),
    /// so the location is resolved rather than assembled.
    private static func copyLocalPath(of identifier: NSFileProviderItemIdentifier) async throws {
        let location = try await FinderDomain.manager().getUserVisibleURL(for: identifier)
        try await copyToPasteboard(location.path)
    }

    /// Replaces the clipboard contents from this extension's process.
    private static func copyToPasteboard(_ text: String) async throws {
        let didWrite = await MainActor.run {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            return pasteboard.setString(text, forType: .string)
        }
        guard didWrite else {
            log.error("Pasteboard refused the copied path")
            throw CustomActionError.pasteboardUnavailable
        }
        log.debug("Copied \(text)")
    }

    /// Removes the server from the mounted set, then brings the Finder
    /// location in line with what is left. The app and this extension share
    /// that set through the App Group.
    private static func unmountServer(_ serverID: UUID) async throws -> AfterCompletion? {
        let remainingServerIDs = try MountedServersStore().removeMountedServer(serverID)
        guard remainingServerIDs.isEmpty else {
            try await FinderDomain.synchronize(hasMountedServers: true)
            return nil
        }
        return { await hideDomain() }
    }

    /// Records that the user wants the selection kept on this Mac, or no
    /// longer wants it.
    ///
    /// Records the pin, then — once the action is reported done — has the
    /// system look again and, for a new pin, fetch the content.
    ///
    /// The pin itself only has to be written: the item reports it, and the
    /// cache sweep reads the same file. The system learns of it through the
    /// item's metadata version, which is why the pin is part of that version
    /// and why each parent is queued for a refresh: the badge and the menu
    /// entry change the moment the system looks, not the next time it
    /// happens to. The keep-downloaded policy alone leaves the download to
    /// the background downloader and its own idea of a convenient time — a
    /// 4 GB file pinned days ago was still dataless — so the download is
    /// asked for outright.
    private static func setPinned(_ isPinned: Bool, on entities: [ProviderEntity]) throws -> AfterCompletion? {
        let store = try PinnedItemsStore()
        var parents: Set<DirectoryRefreshQueue.Entry> = []
        var items: [NSFileProviderItemIdentifier] = []
        for entity in entities {
            guard case .item = entity, let serverID = entity.serverID else { continue }
            let identifier = ItemIdentifierMapper.identifier(for: entity)
            try store.setPinned(isPinned, for: identifier.rawValue)
            items.append(identifier)
            parents.insert(.init(serverID: serverID, path: RemotePath.parent(of: entity.path)))
        }
        PinnedItems.invalidate()
        log.notice("\(isPinned ? "Pinned" : "Unpinned") \(items.count) items")
        return {
            await refresh(parents)
            if isPinned {
                await download(items)
            }
        }
    }

    /// Asks the system to list what the selection shows again.
    ///
    /// The working-set enumerator only re-lists directories found in the
    /// queue, so signalling alone refreshes nothing: the folders selected go
    /// in, and for a file the folder that holds it.
    private static func refresh(
        _ entities: [ProviderEntity], identifiers: [NSFileProviderItemIdentifier]
    ) async throws {
        var directories: Set<DirectoryRefreshQueue.Entry> = []
        for (entity, identifier) in zip(entities, identifiers) {
            switch entity {
            case .root:
                for config in try ConnectionRegistry.mountedConfigs() {
                    directories.insert(.init(serverID: config.id, path: RemotePath.root))
                }
            case .serverRoot(let serverID):
                directories.insert(.init(serverID: serverID, path: RemotePath.root))
            case .item(let serverID, let path):
                let directoryPath = await isDirectory(identifier) ? path : RemotePath.parent(of: path)
                directories.insert(.init(serverID: serverID, path: directoryPath))
            }
        }
        try DirectoryRefreshQueue().enqueue(directories)
        try await FinderDomain.signalWorkingSet()
    }

    /// Whether the item on this Mac is a folder, which the identifier alone
    /// does not say. Reading the attribute does not download anything. When
    /// it cannot be read the answer is no, since listing the parent shows
    /// the item either way.
    private static func isDirectory(_ identifier: NSFileProviderItemIdentifier) async -> Bool {
        guard let url = try? await FinderDomain.manager().getUserVisibleURL(for: identifier) else {
            return false
        }
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func refresh(_ directories: Set<DirectoryRefreshQueue.Entry>) async {
        do {
            try DirectoryRefreshQueue().enqueue(directories)
            try await FinderDomain.signalWorkingSet()
        } catch {
            // The pin is recorded either way; the system picks it up on its
            // next enumeration instead of now.
            log.error("Could not ask for a refresh of \(directories.count) directories: \(error.localizedDescription)")
        }
    }

    private static func download(_ items: [NSFileProviderItemIdentifier]) async {
        for item in items {
            do {
                try await FinderDomain.manager().requestDownloadForItem(
                    withIdentifier: item, requestedRange: NSRange(location: NSNotFound, length: 0))
                log.notice("Download requested for \(item.rawValue)")
            } catch {
                // Still pinned: the background downloader gets to it later.
                log.error("Could not request the download of \(item.rawValue): \(error.localizedDescription)")
            }
        }
    }

    /// Makes the selection dataless again. The system does the actual work
    /// and refuses anything unsafe to drop — unsynced edits, open files — so
    /// one item's refusal must not stop the rest; the failures are summed up
    /// in a single error for Finder to show.
    private static func freeLocalSpace(of entities: [ProviderEntity]) async throws {
        let manager = try FinderDomain.manager()
        var failures: [Error] = []
        for identifier in try evictionTargets(for: entities) {
            try Task.checkCancellation()
            do {
                try await manager.evictItem(identifier: identifier)
            } catch {
                failures.append(error)
                log.error("Could not free local space for \(identifier.rawValue): \(error.localizedDescription)")
            }
        }
        if let firstFailure = failures.first {
            throw CustomActionError.freeLocalSpaceFailed(
                failureCount: failures.count, reason: firstFailure.localizedDescription
            )
        }
    }

    /// The Hamasen root is not an item that can be evicted; freeing it means
    /// freeing every mounted server, which is what a user right-clicking the
    /// location expects.
    private static func evictionTargets(for entities: [ProviderEntity]) throws -> [NSFileProviderItemIdentifier] {
        guard entities.contains(.root) else {
            return entities.map(ItemIdentifierMapper.identifier(for:))
        }
        return try MountedServersStore().loadMountedServerIDs()
            .map { ItemIdentifierMapper.identifier(for: .serverRoot($0)) }
    }

    /// Takes the location out of Finder once nothing is mounted. With nothing
    /// mounted the domain is only hidden, even an outdated one, so no
    /// unsynced edits are moved anywhere that would need recording.
    private static func hideDomain() async {
        do {
            try await FinderDomain.synchronize(hasMountedServers: false)
        } catch {
            log.error("Hiding the Finder location after the last unmount failed: \(error.localizedDescription)")
        }
    }
}

enum CustomActionError: LocalizedError {
    case unknownAction(String)
    case notAHamasenItem
    case notAServerFolder
    case pasteboardUnavailable
    case freeLocalSpaceFailed(failureCount: Int, reason: String)
    case noWebPage
    case cannotOpen(String)

    var errorDescription: String? {
        switch self {
        case .unknownAction(let identifier):
            return String(localized: "不支援的動作：\(identifier)")
        case .notAHamasenItem:
            return String(localized: "這個項目不屬於 Hamasen 掛載")
        case .notAServerFolder:
            return String(localized: "只能從伺服器資料夾卸載")
        case .pasteboardUnavailable:
            return String(localized: "無法寫入剪貼簿")
        case .freeLocalSpaceFailed(let failureCount, let reason):
            return String(localized: "\(failureCount) 個項目無法釋放本機空間：\(reason)")
        case .noWebPage:
            return String(localized: "這個項目沒有網頁")
        case .cannotOpen(let scheme):
            return String(localized: "沒有可以開啟 \(scheme) 連結的 App")
        }
    }
}
