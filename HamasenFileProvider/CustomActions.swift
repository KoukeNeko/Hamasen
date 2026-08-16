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
        case .refresh:
            try await FinderDomain.signalServerListChanged()
            return nil
        case .unmountServer:
            let entity = try singleServerEntity(in: entities)
            guard case .serverRoot(let serverID) = entity else {
                throw CustomActionError.notAServerFolder
            }
            return try await unmountServer(serverID)
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
        let address = "\(config.username)@\(config.host):\(remotePath)"

        let didWrite = await MainActor.run {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            return pasteboard.setString(address, forType: .string)
        }
        guard didWrite else {
            log.error("Pasteboard refused the remote address")
            throw CustomActionError.pasteboardUnavailable
        }
        log.debug("Copied remote address for \(entity.path)")
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

    var errorDescription: String? {
        switch self {
        case .unknownAction(let identifier):
            return "不支援的動作：\(identifier)"
        case .notAHamasenItem:
            return "這個項目不屬於 Hamasen 掛載"
        case .notAServerFolder:
            return "只能從伺服器資料夾卸載"
        case .pasteboardUnavailable:
            return "無法寫入剪貼簿"
        }
    }
}
