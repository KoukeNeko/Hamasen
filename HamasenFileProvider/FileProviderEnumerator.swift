import FileProvider
import Foundation
import HamasenCore

/// Enumerates the mounted servers as folders.
///
/// Used for both the domain root (what Finder shows when the location is
/// opened) and the working set. The working set matters because a replicated
/// extension only receives change signals for that container — signals for
/// any other container are ignored by the system — so mount, unmount, and
/// rename changes have to be reported here to reach Finder.
///
/// The previous server list is carried inside the sync anchor, which is what
/// lets `enumerateChanges` report a precise diff without keeping state
/// between calls.
final class ServerListEnumerator: NSObject, NSFileProviderEnumerator {
    func invalidate() {}

    private static func mountedConfigs() -> [ServerConfig] {
        (try? ConnectionRegistry.mountedConfigs()) ?? []
    }

    private static func anchor(for configs: [ServerConfig]) -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(
            ServerListChangeTracker.encode(ServerListChangeTracker.snapshot(of: configs))
        )
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
        // Read errors must not reach the diff: an empty list would be reported
        // as "every server was deleted" and wipe them from Finder.
        let configs: [ServerConfig]
        do {
            configs = try ConnectionRegistry.mountedConfigs()
        } catch {
            observer.finishEnumeratingWithError(FileProviderErrorMapper.map(error))
            return
        }

        let diff = ServerListChangeTracker.diff(
            previous: ServerListChangeTracker.decode(anchor.rawValue),
            current: configs
        )

        if !diff.updated.isEmpty {
            observer.didUpdate(diff.updated.map(ServerFolderItem.init))
        }
        if !diff.removedServerIDs.isEmpty {
            observer.didDeleteItems(
                withIdentifiers: diff.removedServerIDs.compactMap { serverID in
                    UUID(uuidString: serverID).map {
                        ItemIdentifierMapper.identifier(for: .serverRoot($0))
                    }
                }
            )
        }
        observer.finishEnumeratingChanges(upTo: Self.anchor(for: configs), moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(Self.anchor(for: Self.mountedConfigs()))
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
