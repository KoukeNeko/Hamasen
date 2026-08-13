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
    private let log = HamasenLog(category: "FinderSync")

    /// Where the domain is mounted, as published by the app.
    ///
    /// Never resolved here: asking fileproviderd from this sandbox hangs
    /// without an answer, so the app resolves the location and shares it
    /// through the App Group defaults. Finder calls `menu(for:)`
    /// synchronously, which also rules out waiting on anything async.
    private var mountRoot: URL?

    /// Cross-process defaults offer no change notification, and this
    /// extension usually outlives many app launches — including the very
    /// first one that ever publishes the location — so it re-reads on a
    /// slow clock instead of only once at start.
    private static let publishedLocationPollInterval: TimeInterval = 2

    private var publishedLocationMonitor: DispatchSourceTimer?

    override init() {
        super.init()

        // Finder may reuse extension state across app launches. Clear any
        // previously claimed location before asynchronously adopting the
        // current value published by the app.
        FIFinderSyncController.default().directoryURLs = []
        startPublishedLocationMonitor()
    }

    deinit {
        publishedLocationMonitor?.setEventHandler {}
        publishedLocationMonitor?.cancel()
    }

    /// Claims the published location whenever it appears or moves.
    private func adoptPublishedMountRoot() {
        let published = FinderDomain.publishedUserVisibleLocation()
        guard published != mountRoot else { return }

        mountRoot = published
        FIFinderSyncController.default().directoryURLs = published.map { [$0] } ?? []

        guard let published else {
            // Without a claimed directory Finder never shows the menu, so
            // this must be visible even without debug logging.
            log.error("No published mount location; context menu stays hidden")
            return
        }
        log.debug("Watching \(published.path)")
    }

    /// Dispatch source timers stay attached to the requested queue even when
    /// Finder creates the extension from a thread without a running RunLoop.
    /// Holding and cancelling the source also makes its lifetime match this
    /// extension instance instead of leaking a scheduled Timer into Finder.
    private func startPublishedLocationMonitor() {
        let start = { [weak self] in
            guard let self, self.publishedLocationMonitor == nil else { return }

            let monitor = DispatchSource.makeTimerSource(queue: .main)
            monitor.schedule(
                deadline: .now(),
                repeating: Self.publishedLocationPollInterval,
                leeway: .milliseconds(250)
            )
            monitor.setEventHandler { [weak self] in
                self?.adoptPublishedMountRoot()
            }
            self.publishedLocationMonitor = monitor
            monitor.resume()
        }

        if Thread.isMainThread {
            start()
        } else {
            DispatchQueue.main.async(execute: start)
        }
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems || menuKind == .contextualMenuForContainer else {
            return nil
        }
        guard let target = currentTarget() else {
            log.debug("No menu: selection did not resolve to a mounted server")
            return nil
        }

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
            do {
                let store = try MountedServersStore()
                var mounted = try store.loadMountedServerIDs()
                guard mounted.remove(target.server.id) != nil else { return }

                try store.saveMountedServerIDs(mounted)
                let preservedLocation = try await FinderDomain.synchronize(
                    hasMountedServers: !mounted.isEmpty
                )
                // Content that never made it to the server survives the
                // unmount; showing it is the only way the user learns it is
                // there.
                if let preservedLocation {
                    NSWorkspace.shared.activateFileViewerSelecting([preservedLocation])
                }
            } catch {
                log.error("Unmounting from Finder failed: \(error.localizedDescription)")
            }
        }
    }
}
