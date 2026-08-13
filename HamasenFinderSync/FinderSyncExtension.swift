import AppKit
import FileProvider
import FinderSync
import HamasenCore

/// Adds Hamasen's own entries to the Finder context menu.
///
/// This is a FinderSync extension rather than File Provider custom actions:
/// on macOS, Finder builds its context menu from FinderSync extensions —
/// `NSExtensionFileProviderActions` is the iOS Files app mechanism, and Finder
/// never queries it. Every other provider that adds menu entries (Google
/// Drive, Synology Drive) ships a FinderSync extension alongside its provider
/// for the same reason.
final class FinderSyncExtension: FIFinderSync {
    /// Where the domain is mounted. Finder calls `menu(for:)` synchronously on
    /// the main thread, so the location has to be resolved ahead of time.
    private var mountRoot: URL?

    override init() {
        super.init()
        // Finder only offers a menu inside the directories we claim, and the
        // location is only known once the domain exists.
        Task { @MainActor in
            guard let mountRoot = await MountLocator.mountRoot() else { return }
            self.mountRoot = mountRoot
            FIFinderSyncController.default().directoryURLs = [mountRoot]
        }
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems || menuKind == .contextualMenuForContainer else {
            return nil
        }
        guard let target = currentTarget() else { return nil }

        let menu = NSMenu(title: "")
        menu.addItem(item(titled: "複製遠端路徑", action: #selector(copyRemotePath(_:)), for: target))
        menu.addItem(item(titled: "重新整理", action: #selector(refresh(_:)), for: target))
        if target.isServerRoot {
            menu.addItem(
                item(titled: "從 Finder 卸載此伺服器", action: #selector(unmountServer(_:)), for: target)
            )
        }
        return menu
    }

    /// The item the menu applies to: the selection when there is one, the
    /// browsed folder otherwise.
    private func currentTarget() -> MountedLocation? {
        let controller = FIFinderSyncController.default()
        guard let mountRoot,
              let url = controller.selectedItemURLs()?.first ?? controller.targetedURL()
        else { return nil }
        return MountLocator.location(of: url, under: mountRoot)
    }

    private func item(titled title: String, action: Selector, for target: MountedLocation) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.representedObject = target
        return item
    }

    // MARK: - Actions

    /// Puts the address the item has *on the server* on the clipboard, which
    /// is what you need to reach it over ssh or in another client.
    @objc private func copyRemotePath(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? MountedLocation else { return }
        let remotePath = RemotePath.resolve(target.path, against: target.server.remotePath)

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            "\(target.server.username)@\(target.server.host):\(remotePath)",
            forType: .string
        )
    }

    /// Remote changes are not pushed, so this asks the system to re-enumerate.
    @objc private func refresh(_ sender: NSMenuItem) {
        Task {
            try? await FinderDomain.signalServerListChanged()
        }
    }

    /// Removes the server from the mounted set, then brings the Finder
    /// location in line with what is left. The app and this extension share
    /// that list through the App Group.
    @objc private func unmountServer(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? MountedLocation else { return }
        Task {
            let store = try MountedServersStore()
            var mounted = try store.loadMountedServerIDs()
            guard mounted.remove(target.server.id) != nil else { return }

            try store.saveMountedServerIDs(mounted)
            try await FinderDomain.synchronize(hasMountedServers: !mounted.isEmpty)
        }
    }
}
