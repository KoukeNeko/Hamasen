import AppKit
import HamasenCore
import SwiftUI

@main
struct HamasenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// One shared model serves the main window and the menu bar extra.
    @State private var model: ServerListModel

    init() {
        // Before any credential is read: builds before App Store
        // distribution kept them in the file-based Keychain.
        FileKeychainImport.runIfNeeded()

        let model = ServerListModel()
        _model = State(initialValue: model)

        // Registering the domain must not depend on a window or the menu-bar
        // popover being opened, so the mounted set is loaded as soon as the
        // app starts.
        Task { @MainActor in
            await model.loadIfNeeded()
        }
    }

    @AppStorage(AppOnlyDefaults.showMenuBarIcon) private var showMenuBarIcon = true

    var body: some Scene {
        WindowGroup(id: "main") {
            HamasenMainView(model: model)
        }

        Settings {
            SettingsView()
        }

        MenuBarExtra(
            "Hamasen",
            systemImage: "externaldrive.connected.to.line.below",
            isInserted: $showMenuBarIcon
        ) {
            MenuBarContentView(model: model)
        }
        // A window rather than a menu: progress bars and usage figures are
        // not menu items.
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DockIconController.applyStoredPreference()
        // Recorded now so a later comparison reflects the language this
        // process actually launched with, not one chosen since.
        AppLanguage.captureLaunchState()
    }
}
