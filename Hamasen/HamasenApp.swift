import AppKit
import Darwin
import HamasenCore
import SwiftUI

@main
struct HamasenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// One shared model serves the main window and the menu bar extra.
    @State private var model: ServerListModel

    init() {
        // Must precede any store access: the model and both extensions read
        // from the new App Group, and this fills it from the legacy one.
        let arguments = CommandLine.arguments
        let migrationArgumentIndex = arguments.firstIndex(of: "--migrate-legacy-group-only")
        let targetAppURL = migrationArgumentIndex.flatMap { index -> URL? in
            let pathIndex = arguments.index(after: index)
            guard pathIndex < arguments.endIndex else { return nil }
            return URL(fileURLWithPath: arguments[pathIndex], isDirectory: true)
        }
        let migrationComplete = migrationArgumentIndex.map { _ in
            LegacyGroupMigration.runIfNeeded(
                credentialConsumerAppURL: targetAppURL,
                force: true
            )
        }
        let model = ServerListModel()
        _model = State(initialValue: model)
        if migrationArgumentIndex != nil {
            Darwin.exit(migrationComplete == true ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        if arguments.contains("--verify-credentials-only") {
            do {
                for config in try ServerConfigStore().loadServers() {
                    _ = try KeychainCredentialStore().loadCredentials(for: config)
                }
                if arguments.contains("--finalize-migration") {
                    LegacyGroupMigration.finalizeMigration()
                }
                Darwin.exit(EXIT_SUCCESS)
            } catch {
                Darwin.exit(EXIT_FAILURE)
            }
        }
        if arguments.contains("--rollback-uncommitted-credentials") {
            Darwin.exit(
                LegacyGroupMigration.rollbackUncommittedCredentials()
                    ? EXIT_SUCCESS
                    : EXIT_FAILURE
            )
        }

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
