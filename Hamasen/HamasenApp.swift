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
import UserNotifications

/// Where the main window is and where it has been, shared with the menu
/// bar panel so it can open the window on a particular connection.
///
/// Like System Settings, one pair of back and forward buttons covers both
/// moving between panes and going into a page within one, so both are kept
/// as one history.
@MainActor
@Observable
final class AppNavigation {
    /// A place the window can show: a sidebar item, and the pages opened
    /// within it.
    struct Location: Hashable {
        var item: SidebarItem?
        var pages: [SettingsPage] = []
    }

    private(set) var current = Location()
    private var backStack: [Location] = []
    private var forwardStack: [Location] = []

    var isAddingConnection = false

    var selection: SidebarItem? {
        get { current.item }
        set {
            guard newValue != current.item else { return }
            go(to: Location(item: newValue))
        }
    }

    /// The pages opened within the selected pane, the last one showing.
    var pages: [SettingsPage] {
        get { current.pages }
        set {
            guard newValue != current.pages else { return }
            go(to: Location(item: current.item, pages: newValue))
        }
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(current)
        current = previous
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(current)
        current = next
    }

    private func go(to location: Location) {
        // The pane the window opens on is where history starts, not a step
        // to go back to.
        if current.item != nil { backStack.append(current) }
        forwardStack.removeAll()
        current = location
    }
}

@main
struct HamasenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// One shared model serves the main window and the menu bar.
    @State private var model: ServerListModel
    @State private var navigation = AppNavigation()
    @State private var guide = GettingStarted()

    init() {
        // Before any credential is read: builds before App Store
        // distribution kept them in the file-based Keychain.
        FileKeychainImport.runIfNeeded()

        let model = ServerListModel()
        _model = State(initialValue: model)

        // Registering the domain must not depend on a window or the menu-bar
        // panel being opened, so the mounted set is loaded as soon as the
        // app starts.
        Task { @MainActor in
            await model.loadIfNeeded()
        }
    }

    @AppStorage(AppOnlyDefaults.showMenuBarIcon) private var showMenuBarIcon = true

    var body: some Scene {
        // One window, not a group of them. A group makes another every time
        // openWindow asks for this identifier, so opening Hamasen from the
        // menu bar built up a pile of identical windows.
        Window(AppInfo.displayName, id: "main") {
            HamasenMainView(model: model, guide: guide, navigation: navigation)
        }
        .windowToolbarStyle(.unified)
        // Launched as a login item, the app mounts in the background and
        // stays out of the way; the window opens when it is asked for.
        .defaultLaunchBehavior(AppDelegate.launchedAsLoginItem ? .suppressed : .presented)
        .commands { commands }

        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarContentView(model: model, navigation: navigation)
        } label: {
            Image(systemName: model.overallStatus.symbol)
                .accessibilityLabel(Text(verbatim: "\(AppInfo.displayName) — \(model.overallStatus.title)"))
        }
        // A window rather than a menu: progress bars and usage figures are
        // not menu items.
        .menuBarExtraStyle(.window)
    }

    @CommandsBuilder
    private var commands: some Commands {
        CommandGroup(after: .appInfo) {
            if model.updates.isAvailable {
                CheckForUpdatesButton(updates: model.updates, navigation: navigation)
            }
        }
        // Settings live in the main window's sidebar, as System Settings
        // keeps its own panes, so ⌘, opens them there.
        CommandGroup(replacing: .appSettings) {
            OpenPaneButton(title: "設定…", pane: .general, navigation: navigation)
                .keyboardShortcut(",")
        }
        CommandGroup(replacing: .newItem) {
            NewConnectionButton(navigation: navigation)
        }
        // Where System Settings keeps them, with the same shortcuts.
        CommandGroup(before: .sidebar) {
            Button("返回") { navigation.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!navigation.canGoBack)
            Button("前進") { navigation.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!navigation.canGoForward)
            Divider()
        }
        // Show and hide the overview's transfer details from the View menu
        // and with ⌃⌘I, as everywhere else on the Mac.
        InspectorCommands()
        CommandGroup(replacing: .help) {
            OpenPaneButton(title: "開始使用", navigation: navigation) {
                guide.isDismissed = false
                navigation.selection = .gettingStarted
            }
            Divider()
            Link("隱私權政策", destination: GitHubRepository.privacyPolicyURL)
            Link("支援", destination: GitHubRepository.supportURL)
            Link("回報問題", destination: GitHubRepository.issuesURL)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let notificationPresenter = NotificationPresenter()

    /// Whether this launch was the login item starting the app. Read from
    /// the launch event before any scene asks, which is why it is computed
    /// once, here.
    static let launchedAsLoginItem: Bool = {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }()

    func applicationWillFinishLaunching(_ notification: Notification) {
        _ = Self.launchedAsLoginItem
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DockIconController.applyStoredPreference()
        // Recorded now so a later comparison reflects the language this
        // process actually launched with, not one chosen since.
        AppLanguage.captureLaunchState()
        UNUserNotificationCenter.current().delegate = notificationPresenter
    }

    /// Closing the window leaves the mounts and the menu bar running, which
    /// is where the app lives.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// A menu command that brings the main window forward on one of its panes,
/// opening the window if it was closed.
private struct OpenPaneButton: View {
    let title: LocalizedStringKey
    var pane: SettingsPane?
    let navigation: AppNavigation
    var action: (() -> Void)?

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(title) {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
            if let pane { navigation.selection = .settings(pane) }
            action?()
        }
    }
}

/// "Check for Updates…" in the app menu: starts a check and shows its
/// answer in the Software Update pane.
private struct CheckForUpdatesButton: View {
    let updates: UpdateChecker
    let navigation: AppNavigation

    var body: some View {
        OpenPaneButton(title: "檢查更新…", pane: .updates, navigation: navigation) {
            Task { await updates.check() }
        }
    }
}

/// "New Connection…" in the File menu, opening the window if it is closed.
private struct NewConnectionButton: View {
    let navigation: AppNavigation
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("新增連線…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
            navigation.isAddingConnection = true
        }
        .keyboardShortcut("n")
    }
}
