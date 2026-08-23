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
    let model: ServerListModel

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("一般", systemImage: "gearshape") }
            ConnectionSettingsView()
                .tabItem { Label("連線", systemImage: "network") }
            AdvancedSettingsView(model: model)
                .tabItem { Label("進階", systemImage: "wrench.and.screwdriver") }
            AboutSettingsView()
                .tabItem { Label("關於", systemImage: "info.circle") }
        }
        // A minimum rather than a fixed height: the tabs differ in length —
        // About grows with the number of contributors — and a window sized to
        // the shortest of them makes the others scroll for no reason.
        .frame(width: 460)
        // Separately, because a fixed width and a minimum height cannot be
        // asked for in one call: the tabs differ in length — About grows with
        // the number of contributors — and sizing the window to the shortest
        // of them makes the others scroll for no reason.
        .frame(minHeight: 480)
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
                Text("掛載由系統維持，不需要 App 常駐。但本機空間上限是 App 執行時才清理的，有設上限就建議開啟。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("顯示選單列圖示", isOn: $showMenuBarIcon)
                    .disabled(isOnlyMenuBarIcon)
                Toggle("顯示 Dock 圖示", isOn: showsDockIcon)
                    .disabled(isOnlyDockIcon)
            } footer: {
                Text("至少要保留一個，否則沒有地方可以開啟 Hamasen。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LanguageSection()
        }
        .formStyle(.grouped)
    }

    /// The Dock icon is stored as the hidden state, which is what earlier
    /// versions wrote, but reads as "shown" here so both switches mean the
    /// same thing when they are on.
    private var showsDockIcon: Binding<Bool> {
        Binding(
            get: { !hideDockIcon },
            set: { isShown in
                hideDockIcon = !isShown
                DockIconController.setHidden(!isShown)
            }
        )
    }

    /// Whichever icon is the last one showing cannot be turned off: with both
    /// gone there is nothing left to open Hamasen from. Disabling it says so
    /// in place, where silently switching the other one back on did not.
    private var isOnlyMenuBarIcon: Bool { showMenuBarIcon && hideDockIcon }
    private var isOnlyDockIcon: Bool { !hideDockIcon && !showMenuBarIcon }

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
            // Established by trying it: giving the extension its own language
            // preference changes nothing, because Finder builds that menu and
            // reads the names in its own language, not the extension's.
            Text("Finder 右鍵選單是由 Finder 繪製的，跟著系統語言走，不受這裡影響。要改的話請在「系統設定 › 一般 › 語言與地區」調整語言順序。")
                .font(.caption)
                .foregroundStyle(.secondary)
                // A wrapped footer is measured as one line unless it is told
                // to keep its own height, and the window then clips it.
                .fixedSize(horizontal: false, vertical: true)
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
    let model: ServerListModel

    @AppStorage(AppSettings.Keys.debugLoggingEnabled, store: AppSettings.sharedStore)
    private var debugLoggingEnabled = false

    var body: some View {
        Form {
            BackupSection(model: model)

            IndexingSection()

            RemoteChangeSection()

            S3UploadSection()

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

/// How often, if at all, the app asks a server what changed.
private struct RemoteChangeSection: View {
    @AppStorage(AppSettings.Keys.remoteChangePollSeconds, store: AppSettings.sharedStore)
    private var pollSeconds = AppSettings.defaultRemoteChangePollSeconds

    @Environment(ServerListModel.self) private var model

    var body: some View {
        Section {
            Toggle("通知伺服器上的變更", isOn: enabled)
            if pollSeconds != AppSettings.remoteChangePollOff {
                Picker("檢查頻率", selection: interval) {
                    ForEach(RemoteChangePollInterval.allCases) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
            }
        } header: {
            Text("變更通知")
        } footer: {
            // The cost is the point: no protocol here pushes changes, so
            // noticing one means asking, and asking is billed on S3.
            Text("這些協定都不會主動通知，所以只能定期詢問。每次只重新查看你開過的資料夾，每個資料夾一次列舉請求，S3 會計費。預設關閉。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { pollSeconds != AppSettings.remoteChangePollOff },
            set: { isOn in
                pollSeconds = isOn
                    ? RemoteChangePollInterval.fiveMinutes.rawValue
                    : AppSettings.remoteChangePollOff
                model.remoteChanges.restart()
            })
    }

    private var interval: Binding<RemoteChangePollInterval> {
        Binding(
            get: { RemoteChangePollInterval(seconds: pollSeconds) },
            set: {
                pollSeconds = $0.rawValue
                model.remoteChanges.restart()
            })
    }
}

/// How far the background walk goes so Spotlight can index what Finder has
/// not opened.
private struct IndexingSection: View {
    @AppStorage(AppSettings.Keys.indexingDepth, store: AppSettings.sharedStore)
    private var depth = AppSettings.defaultIndexingDepth

    @AppStorage(AppSettings.Keys.indexingDirectoryLimit, store: AppSettings.sharedStore)
    private var directoryLimit = AppSettings.defaultIndexingDirectoryLimit

    @AppStorage(AppSettings.Keys.indexingItemLimit, store: AppSettings.sharedStore)
    private var itemLimit = AppSettings.defaultIndexingItemLimit

    @Environment(ServerListModel.self) private var model

    var body: some View {
        Section {
            Stepper(value: $depth, in: AppSettings.indexingDepthRange) {
                HStack {
                    Text("索引深度")
                    Spacer()
                    Text("\(depth) 層")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Picker("每台伺服器的目錄數上限", selection: directoryLimitSelection) {
                ForEach(IndexingDirectoryLimit.allCases) { limit in
                    Text(limit.displayName).tag(limit)
                }
            }
            Picker("每台伺服器的項目數上限", selection: itemLimitSelection) {
                ForEach(IndexingItemLimit.allCases) { limit in
                    Text(limit.displayName).tag(limit)
                }
            }
        } header: {
            Text("Spotlight 索引")
        } footer: {
            // The cost is named because it is real money on S3 and is not
            // visible anywhere else: the walk happens when nobody is looking.
            Text("Finder 沒開過的資料夾也會在背景列舉，讓 Spotlight 找得到裡面的檔案。每天重新列舉一次，每台伺服器各有自己的上限：目錄數是對伺服器的請求數（S3 會計費），項目數是這台 Mac 要建立的占位檔數。可以在個別伺服器關閉。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: depth) { model.index.settingsChanged() }
        .onChange(of: directoryLimit) { model.index.settingsChanged() }
        .onChange(of: itemLimit) { model.index.settingsChanged() }
    }

    private var directoryLimitSelection: Binding<IndexingDirectoryLimit> {
        Binding(
            get: { IndexingDirectoryLimit(directories: directoryLimit) },
            set: { directoryLimit = $0.rawValue })
    }

    private var itemLimitSelection: Binding<IndexingItemLimit> {
        Binding(
            get: { IndexingItemLimit(items: itemLimit) },
            set: { itemLimit = $0.rawValue })
    }
}

/// How large an upload has to be before it is sent in parts, and how big a
/// part is.
private struct S3UploadSection: View {
    @AppStorage(AppSettings.Keys.s3PartSizeBytes, store: AppSettings.sharedStore)
    private var partSizeBytes = AppSettings.defaultS3PartSizeBytes

    @AppStorage(AppSettings.Keys.s3MultipartThresholdBytes, store: AppSettings.sharedStore)
    private var thresholdBytes = AppSettings.defaultS3MultipartThresholdBytes

    private var partSize: S3PartSize { S3PartSize(bytes: partSizeBytes) }

    var body: some View {
        Section {
            Picker("分段上傳門檻", selection: thresholdSelection) {
                ForEach(S3MultipartThreshold.allCases) { threshold in
                    Text(threshold.displayName).tag(threshold)
                }
            }
            Picker("每段大小", selection: partSizeSelection) {
                ForEach(S3PartSize.allCases) { size in
                    Text(size.displayName).tag(size)
                }
            }
        } header: {
            Text("S3 上傳")
        } footer: {
            // The ceiling is stated because shrinking the part size lowers it
            // silently, and the failure that eventually causes says nothing
            // about which setting caused it.
            Text("超過門檻的檔案會分段上傳。單次上傳最多一萬段，所以目前每段 \(partSize.displayName) 能上傳的最大檔案是 \(partSize.largestUploadDisplayName)。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var partSizeSelection: Binding<S3PartSize> {
        Binding(
            get: { S3PartSize(bytes: partSizeBytes) },
            set: { newValue in
                partSizeBytes = newValue.rawValue
                // A threshold below one part would send a single-part
                // multipart upload. Raising it here keeps what the picker
                // shows equal to what the upload will do, rather than
                // leaving the clamp to happen invisibly on read.
                if thresholdBytes < newValue.rawValue {
                    thresholdBytes = S3MultipartThreshold.allCases
                        .first { $0.rawValue >= newValue.rawValue }?.rawValue
                        ?? newValue.rawValue
                }
            })
    }

    private var thresholdSelection: Binding<S3MultipartThreshold> {
        Binding(
            get: { S3MultipartThreshold(bytes: thresholdBytes) },
            set: { thresholdBytes = $0.rawValue })
    }
}

/// Writes the configuration out and reads one back.
private struct BackupSection: View {
    let model: ServerListModel

    @State private var errorMessage: String?
    @State private var prompt: Prompt?

    /// What the passphrase sheet is being shown for. One piece of state, so
    /// two sheets can never both be up.
    private enum Prompt: Identifiable {
        case protectNewBackup
        case openBackup(Data)

        var id: Int {
            switch self {
            case .protectNewBackup: return 0
            case .openBackup: return 1
            }
        }
    }

    var body: some View {
        Section {
            LabeledContent("設定") {
                HStack {
                    Button("匯出…", action: exportPlain)
                    Button("匯入…", action: importBackup)
                }
            }
            LabeledContent("含密碼的備份") {
                Button("匯出…") { prompt = .protectNewBackup }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("備份")
        } footer: {
            Text("一般備份包含伺服器清單、已記錄的主機金鑰與連線偏好設定，不含密碼與金鑰。含密碼的備份另外包含鑰匙圈裡的所有密碼與金鑰，整份以你設定的密碼加密。匯入時會自動判斷是哪一種。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(item: $prompt) { prompt in
            switch prompt {
            case .protectNewBackup:
                PassphrasePrompt(purpose: .protectNewBackup, onConfirm: exportProtected)
            case .openBackup(let data):
                PassphrasePrompt(purpose: .openBackup) { passphrase in
                    openProtected(data, passphrase: passphrase)
                }
            }
        }
    }

    private func exportPlain() {
        run { _ = try ConfigurationArchiveFile.promptToExport(model.makeArchive()) }
    }

    private func exportProtected(passphrase: String) {
        run {
            _ = try ConfigurationArchiveFile.promptToExport(
                model.makeProtectedArchive(), passphrase: passphrase
            )
        }
    }

    private func importBackup() {
        run {
            switch try ConfigurationArchiveFile.promptToChooseImport() {
            case .plain(let archive):
                model.restore(archive)
            case .protected(let data):
                // Asked for only once it is known there is something locked,
                // rather than of everyone who picks a file.
                prompt = .openBackup(data)
            case nil:
                break
            }
        }
    }

    private func openProtected(_ data: Data, passphrase: String) {
        run {
            model.restore(
                try ProtectedConfigurationArchive.opened(data, passphrase: passphrase)
            )
        }
    }

    private func run(_ work: () throws -> Void) {
        do {
            try work()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    SettingsView(model: ServerListModel())
}
