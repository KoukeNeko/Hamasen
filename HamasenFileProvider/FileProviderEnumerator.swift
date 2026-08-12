import FileProvider
import Foundation
import HamasenCore

/// Enumerates the domain root: one folder per mounted server.
///
/// The sync anchor is a hash of the mounted server list (IDs + names), so
/// mounting, unmounting, or renaming a server invalidates the anchor and the
/// system re-enumerates after the app signals this enumerator.
final class ServerListEnumerator: NSObject, NSFileProviderEnumerator {
    func invalidate() {}

    private static func currentAnchor() -> NSFileProviderSyncAnchor {
        let configs = (try? ConnectionRegistry.mountedConfigs()) ?? []
        let stateToken = configs
            .map { "\($0.id.uuidString):\($0.name)" }
            .sorted()
            .joined(separator: "|")
        return NSFileProviderSyncAnchor(Data(stateToken.utf8))
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        do {
            let items = try ConnectionRegistry.mountedConfigs().map(ServerFolderItem.init)
            observer.didEnumerate(items)
            observer.finishEnumerating(upTo: nil)
        } catch {
            observer.finishEnumeratingWithError(FileProviderErrorMapper.map(error))
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let currentAnchor = Self.currentAnchor()
        if anchor.rawValue == currentAnchor.rawValue {
            observer.finishEnumeratingChanges(upTo: currentAnchor, moreComing: false)
        } else {
            // The server list changed: force a full re-enumeration.
            observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(Self.currentAnchor())
    }
}

/// Enumerates one remote directory of one server.
final class DirectoryEnumerator: NSObject, NSFileProviderEnumerator {
    /// No server-side change tracking in the MVP: a constant anchor plus
    /// "no changes" responses; Finder refreshes re-enumerate directories.
    private static let staticSyncAnchor = NSFileProviderSyncAnchor(Data("hamasen-static-anchor".utf8))

    private let serverID: UUID
    private let directoryPath: String
    private let registry: ConnectionRegistry

    init(serverID: UUID, directoryPath: String, registry: ConnectionRegistry) {
        self.serverID = serverID
        self.directoryPath = directoryPath
        self.registry = registry
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let serverID = serverID
        let directoryPath = directoryPath
        let registry = registry
        Task {
            do {
                let service = try await registry.service(for: serverID)
                let items = try await service.listDirectory(at: directoryPath)
                observer.didEnumerate(items.map { RemoteFileItem(serverID: serverID, remoteItem: $0) })
                observer.finishEnumerating(upTo: nil)
            } catch {
                observer.finishEnumeratingWithError(FileProviderErrorMapper.map(error))
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: Self.staticSyncAnchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(Self.staticSyncAnchor)
    }
}

/// Enumerator for containers the MVP does not track (e.g. the working set):
/// always empty.
final class EmptyEnumerator: NSObject, NSFileProviderEnumerator {
    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Data("empty".utf8)))
    }
}
