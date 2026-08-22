// Copyright 2026 KoukeNeko
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

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

    /// The window's title comes from the app's own name, which is localized
    /// in the Info.plist catalog, rather than being written out again here.
    private static var windowTitle: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Hamasen"
    }

    var body: some Scene {
        // One window, not a group of them. A group makes another every time
        // openWindow asks for this identifier, so opening Hamasen from the
        // menu bar built up a pile of identical windows — each showing the
        // same alert, since they all watch the same model.
        Window(Self.windowTitle, id: "main") {
            HamasenMainView(model: model)
        }

        Settings {
            SettingsView(model: model)
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
