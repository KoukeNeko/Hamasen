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
                let afterCompletion = try await CustomActionRunner.run(action, on: itemIdentifiers)
                completionHandler(nil)
                await afterCompletion?()
            } catch is CancellationError {
                completionHandler(CocoaError(.userCancelled))
            } catch {
                completionHandler(error)
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }
}

/// Executes one context-menu action on the selection Finder passed along.
enum CustomActionRunner {
    private static let log = HamasenLog(category: "CustomActions")

    /// Work that must wait until the system has been told the action is
    /// done. Only unmounting the last server needs it: removing the domain
    /// stops this very extension, so it cannot happen before the completion
    /// is reported.
    typealias AfterCompletion = () async -> Void

    static func run(
        _ action: FinderAction,
        on itemIdentifiers: [NSFileProviderItemIdentifier]
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
            try await FinderDomain.signalServerListChanged()
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
        }
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
        return { await removeDomainPreservingEdits() }
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

    /// Content that never reached the server survives the removal, but by the
    /// time its location is known this process may already be gone, so it is
    /// recorded rather than revealed.
    private static func removeDomainPreservingEdits() async {
        do {
            if let preservedLocation = try await FinderDomain.synchronize(hasMountedServers: false) {
                log.notice("Unsynced edits were preserved at \(preservedLocation.path)")
            }
        } catch {
            log.error("Removing the Finder location after the last unmount failed: \(error.localizedDescription)")
        }
    }
}

enum CustomActionError: LocalizedError {
    case unknownAction(String)
    case notAHamasenItem
    case notAServerFolder
    case pasteboardUnavailable
    case freeLocalSpaceFailed(failureCount: Int, reason: String)

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
        }
    }
}
