import AppKit
import FileProvider
import Foundation
import HamasenCore

/// The entries Hamasen adds to the Finder context menu.
///
/// A replicated extension declares its actions in its own Info.plist and runs
/// them here, rather than in a FileProviderUI extension; see
/// `NSFileProviderCustomAction` in NSFileProviderReplicatedExtension.h. None
/// of them need to ask the user anything, so none of them present a window.
enum CustomAction: String {
    case copyRemotePath = "dev.hamasen.action.copyRemotePath"
    case refresh = "dev.hamasen.action.refresh"
    case unmountServer = "dev.hamasen.action.unmountServer"

    /// Runs the action on the first selected item.
    ///
    /// The activation rules in Info.plist already restrict every action to a
    /// single selection, so a second item would be ambiguous rather than
    /// meaningful.
    func run(on itemIdentifiers: [NSFileProviderItemIdentifier]) async throws {
        guard let identifier = itemIdentifiers.first,
              let entity = ItemIdentifierMapper.entity(for: identifier),
              let serverID = entity.serverID
        else {
            throw CustomActionError.notAHamasenItem
        }

        switch self {
        case .copyRemotePath:
            try Self.copyRemotePath(of: entity, on: serverID)
        case .refresh:
            try await FinderDomain.signalServerListChanged()
        case .unmountServer:
            try await Self.unmountServer(serverID)
        }
    }

    /// Puts the address the item has *on the server* on the clipboard, which
    /// is what you need to reach it over ssh or in another client.
    private static func copyRemotePath(of entity: ProviderEntity, on serverID: UUID) throws {
        let config = try config(for: serverID)
        let remotePath = RemotePath.resolve(entity.path, against: config.remotePath)

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            "\(config.username)@\(config.host):\(remotePath)",
            forType: .string
        )
    }

    /// Removes the server from the mounted set, then brings the Finder
    /// location in line with what is left. The app and this extension share
    /// that list through the App Group.
    private static func unmountServer(_ serverID: UUID) async throws {
        let store = try MountedServersStore()
        var mounted = try store.loadMountedServerIDs()
        guard mounted.remove(serverID) != nil else { return }

        try store.saveMountedServerIDs(mounted)
        try await FinderDomain.synchronize(hasMountedServers: !mounted.isEmpty)
    }

    private static func config(for serverID: UUID) throws -> ServerConfig {
        guard let config = try ServerConfigStore().server(withID: serverID) else {
            throw CustomActionError.serverMissing
        }
        return config
    }
}

enum CustomActionError: LocalizedError {
    case unknownAction(String)
    case notAHamasenItem
    case serverMissing

    var errorDescription: String? {
        switch self {
        case .unknownAction(let identifier):
            return "不支援的動作：\(identifier)"
        case .notAHamasenItem:
            return "這個項目不屬於 Hamasen 掛載"
        case .serverMissing:
            return "找不到對應的伺服器設定"
        }
    }
}

extension FileProviderExtension: NSFileProviderCustomAction {
    func performAction(
        identifier actionIdentifier: NSFileProviderExtensionActionIdentifier,
        onItemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        guard let action = CustomAction(rawValue: actionIdentifier.rawValue) else {
            completionHandler(CustomActionError.unknownAction(actionIdentifier.rawValue))
            progress.completedUnitCount = 1
            return progress
        }

        Task {
            do {
                try await action.run(on: itemIdentifiers)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
            progress.completedUnitCount = 1
        }
        return progress
    }
}
