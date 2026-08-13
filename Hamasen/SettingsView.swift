import FinderSync
import HamasenCore
import ServiceManagement
import SwiftUI

/// Keys for app-only preferences (the extension never reads these, so they
/// stay in the app's standard defaults).
enum AppOnlyDefaults {
    static let showMenuBarIcon = "showMenuBarIcon"
    static let hideDockIcon = "hideDockIcon"
}

/// The Settings window (⌘,), split into General / Connection / Advanced.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("一般", systemImage: "gearshape") }
            ConnectionSettingsView()
                .tabItem { Label("連線", systemImage: "network") }
            AdvancedSettingsView()
                .tabItem { Label("進階", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 440)
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @AppStorage(AppOnlyDefaults.showMenuBarIcon) private var showMenuBarIcon = true
    @AppStorage(AppOnlyDefaults.hideDockIcon) private var hideDockIcon = false

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("登入時啟動", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, isEnabled in
                        applyLaunchAtLogin(isEnabled)
                    }
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } footer: {
                Text("掛載由系統維持，App 不需常駐；登入時啟動只是讓選單列圖示隨時可用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("顯示選單列圖示", isOn: $showMenuBarIcon)
                    .onChange(of: showMenuBarIcon) { _, isShown in
                        if !isShown && hideDockIcon {
                            // Never allow both to be hidden at once.
                            hideDockIcon = false
                            DockIconController.setHidden(false)
                        }
                    }
                Toggle("隱藏 Dock 圖示（純選單列模式）", isOn: $hideDockIcon)
                    .disabled(!showMenuBarIcon)
                    .onChange(of: hideDockIcon) { _, isHidden in
                        DockIconController.setHidden(isHidden)
                    }
            } footer: {
                Text("隱藏 Dock 圖示後，從選單列圖示即可開啟主視窗。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            FinderExtensionSection()
        }
        .formStyle(.grouped)
    }

    private func applyLaunchAtLogin(_ isEnabled: Bool) {
        do {
            if isEnabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            launchAtLoginError = "無法變更登入啟動設定：\(error.localizedDescription)"
        }
    }
}

/// Reports whether the Finder context menu is available, and offers the one
/// route to turning it on.
///
/// macOS enables a Finder extension only through the user's own action in
/// System Settings — there is no programmatic switch — and it is filed under
/// the Finder extension category rather than beside the app's file provider,
/// which makes it easy to miss. `showExtensionManagementInterface` opens the
/// exact pane.
private struct FinderExtensionSection: View {
    @State private var isEnabled = FIFinderSyncController.isExtensionEnabled

    var body: some View {
        Section {
            LabeledContent("Finder 右鍵選單") {
                HStack(spacing: 8) {
                    Image(systemName: isEnabled ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(isEnabled ? .green : .orange)
                    Text(isEnabled ? "已啟用" : "尚未啟用")
                        .foregroundStyle(.secondary)
                }
            }
            if !isEnabled {
                Button("在系統設定中啟用…") {
                    FIFinderSyncController.showExtensionManagementInterface()
                }
            }
        } footer: {
            Text("啟用後，在掛載的檔案上按右鍵可複製遠端路徑、重新整理或卸載伺服器。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // The switch is flipped in another app, so re-read on return.
            isEnabled = FIFinderSyncController.isExtensionEnabled
        }
    }
}

/// Applies the Dock-icon visibility preference to the running app.
enum DockIconController {
    static func setHidden(_ isHidden: Bool) {
        NSApp.setActivationPolicy(isHidden ? .accessory : .regular)
        if !isHidden {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Called once at launch to restore the stored preference.
    static func applyStoredPreference() {
        let defaults = UserDefaults.standard
        let showMenuBar = defaults.object(forKey: AppOnlyDefaults.showMenuBarIcon) as? Bool ?? true
        if showMenuBar && defaults.bool(forKey: AppOnlyDefaults.hideDockIcon) {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

// MARK: - Connection

private struct ConnectionSettingsView: View {
    @AppStorage(AppSettings.Keys.connectTimeoutSeconds, store: AppSettings.sharedStore)
    private var connectTimeoutSeconds = AppSettings.defaultConnectTimeoutSeconds

    @AppStorage(AppSettings.Keys.defaultServerPort, store: AppSettings.sharedStore)
    private var defaultServerPort = ServerConfig.defaultSFTPPort

    var body: some View {
        Form {
            Section {
                Stepper(value: $connectTimeoutSeconds, in: AppSettings.connectTimeoutRange, step: 5) {
                    HStack {
                        Text("連線逾時")
                        Spacer()
                        Text("\(connectTimeoutSeconds) 秒")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            } footer: {
                Text("已掛載伺服器的連線也適用；變更會在下次連線時生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField(
                    "新伺服器預設連接埠",
                    value: $defaultServerPort,
                    format: .number.grouping(.never)
                )
            } footer: {
                Text("只影響「新增伺服器」表單的預設值，不會改動既有伺服器。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Advanced

private struct AdvancedSettingsView: View {
    @AppStorage(AppSettings.Keys.debugLoggingEnabled, store: AppSettings.sharedStore)
    private var debugLoggingEnabled = false

    var body: some View {
        Form {
            Section {
                Toggle("啟用除錯記錄", isOn: $debugLoggingEnabled)
            } footer: {
                Text("在 Console.app 以子系統 dev.hamasen 檢視記錄。App 與 File Provider 擴充功能都會套用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    SettingsView()
}
