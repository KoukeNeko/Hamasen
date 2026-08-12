import AppKit
import SwiftUI

@main
struct HamasenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// One shared model serves the main window and the menu bar extra.
    @State private var model = ServerListModel()

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
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DockIconController.applyStoredPreference()
    }
}
