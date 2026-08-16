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

            LanguageSection()
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

/// Chooses the language Hamasen runs in.
///
/// The picker writes the same per-app preference System Settings does, so both
/// places show the same answer; the relaunch prompt appears because no
/// mechanism, Apple's included, can change a running app's language.
private struct LanguageSection: View {
    @State private var selection = AppLanguage.selected
    @State private var needsRelaunch = AppLanguage.needsRelaunch

    var body: some View {
        Section {
            Picker("語言", selection: $selection) {
                Text("跟隨系統").tag(AppLanguage.system)
                Divider()
                ForEach(AppLanguage.availableIdentifiers, id: \.self) { identifier in
                    // Each language names itself, as in every macOS language list.
                    Text(AppLanguage.fixed(identifier).endonym ?? identifier)
                        .tag(AppLanguage.fixed(identifier))
                }
            }
            .onChange(of: selection) { _, newSelection in
                newSelection.apply()
                needsRelaunch = AppLanguage.needsRelaunch
            }

            if needsRelaunch {
                LabeledContent("重新啟動後生效") {
                    Button("立即重新啟動") { AppLanguageSettings.relaunch() }
                }
            }

            Button("在系統設定中管理…") { AppLanguageSettings.openSystemLanguageSettings() }
        } footer: {
            Text("Finder 右鍵選單的語言由系統決定，不受這個設定影響。")
                .font(.caption)
                .foregroundStyle(.secondary)
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
