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
import UserNotifications

/// Keys for app-only preferences (the extension never reads these, so they
/// stay in the app's standard defaults).
enum AppOnlyDefaults {
    static let showMenuBarIcon = "showMenuBarIcon"
    static let hideDockIcon = "hideDockIcon"
}

/// The settings panes, listed in the main window's sidebar under 設定 the
/// way System Settings lists its own.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case notifications
    case storage
    case cloud
    case advanced
    case updates
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: return String(localized: "一般")
        case .notifications: return String(localized: "通知")
        case .storage: return String(localized: "本機複本")
        case .cloud: return String(localized: "雲端服務")
        case .advanced: return String(localized: "進階")
        case .updates: return String(localized: "軟體更新")
        case .about: return String(localized: "關於")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .notifications: return "bell.badge.fill"
        case .storage: return "internaldrive.fill"
        case .cloud: return "cloud.fill"
        case .advanced: return "wrench.and.screwdriver.fill"
        case .updates: return "arrow.down.circle.fill"
        case .about: return "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general, .storage, .advanced, .updates: return .gray
        case .notifications: return .red
        case .cloud, .about: return .blue
        }
    }

    /// What the pane holds, under its title in the header card.
    var summary: LocalizedStringKey? {
        switch self {
        case .general: return "登入時啟動、選單列與 Dock 圖示，以及 App 的語言。"
        case .notifications: return "連線中斷、需要重新登入、檔案衝突與新版本。"
        case .storage: return "開啟過的檔案會暫存在這台 Mac，閒置後自動移除。"
        case .cloud: return "Google 雲端硬碟、OneDrive 與 Dropbox 的登入設定。"
        case .advanced: return "連線逾時、Spotlight 索引、S3 上傳、備份與除錯記錄。"
        case .updates: return nil
        case .about: return nil
        }
    }

    /// Words a sidebar search matches besides the title.
    var keywords: [String] {
        switch self {
        case .general: return [String(localized: "登入時啟動"), String(localized: "語言"), "Dock"]
        case .notifications: return [String(localized: "衝突")]
        case .storage: return [String(localized: "自動清理"), String(localized: "下載"), "Finder"]
        case .cloud: return ["Google", "OneDrive", "Dropbox", String(localized: "用戶端 ID")]
        case .advanced: return ["Spotlight", "S3", String(localized: "備份"), String(localized: "書籤"), String(localized: "連線逾時")]
        case .updates: return [String(localized: "版本")]
        case .about: return [String(localized: "隱私權政策"), String(localized: "授權")]
        }
    }

    func matches(_ query: String) -> Bool {
        ([title] + keywords).contains { $0.localizedStandardContains(query) }
    }
}

/// A page within a settings pane, reached from one of its rows.
enum SettingsPage: Hashable {
    case connectionDefaults
    case indexing
    case s3Upload
    case backup
    case debugLogging
    case cloudClient(OAuthProvider)
}

/// One settings pane in the detail column, or the page within it that one
/// of its rows opened.
///
/// The page shown is the last one in the window's history rather than the
/// top of a navigation stack: a stack brings a back button of its own, and
/// the window's back and forward buttons already cover pages, as System
/// Settings' do.
struct SettingsPaneView: View {
    let pane: SettingsPane
    let model: ServerListModel

    @Environment(AppNavigation.self) private var navigation

    var body: some View {
        if let page = navigation.pages.last {
            destination(page)
        } else {
            content
                .navigationTitle(pane.title)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch pane {
        case .general: GeneralSettingsView()
        case .notifications: NotificationSettingsView(showsUpdates: model.updates.isAvailable)
        case .storage: StorageSettingsView(model: model)
        case .cloud: CloudServicesSettingsView()
        case .advanced: AdvancedSettingsView()
        case .updates: UpdateSettingsView(updates: model.updates)
        case .about: AboutSettingsView()
        }
    }

    @ViewBuilder
    private func destination(_ page: SettingsPage) -> some View {
        switch page {
        case .connectionDefaults: ConnectionDefaultsPage()
        case .indexing: AdvancedPage(title: String(localized: "Spotlight 索引")) { IndexingSection(model: model) }
        case .s3Upload: AdvancedPage(title: String(localized: "S3 上傳")) { S3UploadSection() }
        case .backup: BackupPage(model: model)
        case .debugLogging: DebugLoggingPage()
        case .cloudClient(let provider):
            if let service = CloudClientPage.services.first(where: { $0.provider == provider }) {
                CloudClientPage(service: service)
            }
        }
    }
}

/// The card at the top of a pane: its icon, its name, and what it holds.
struct SettingsPaneHeader<Icon: View>: View {
    let title: String
    let summary: LocalizedStringKey?
    @ViewBuilder let icon: Icon

    var body: some View {
        Section {
            VStack(spacing: 8) {
                icon
                Text(title)
                    .font(.title2.bold())
                if let summary {
                    Text(summary)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }
}

extension SettingsPaneHeader where Icon == SymbolTile {
    init(pane: SettingsPane) {
        self.init(title: pane.title, summary: pane.summary) {
            SymbolTile(symbol: pane.symbol, tint: pane.tint, size: 64)
        }
    }
}

/// A row that leads to a page of its own, with an icon and, optionally, a
/// value on the trailing side before the chevron.
struct SettingsNavigationRow<Icon: View>: View {
    let title: String
    var value: String?
    let page: SettingsPage
    @ViewBuilder let icon: Icon

    @Environment(AppNavigation.self) private var navigation

    var body: some View {
        Button {
            navigation.pages.append(page)
        } label: {
            HStack(spacing: 10) {
                icon
                Text(title)
                Spacer()
                if let value {
                    Text(value).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

extension SettingsNavigationRow where Icon == SymbolTile {
    init(title: String, symbol: String, tint: Color, value: String? = nil, page: SettingsPage) {
        self.init(title: title, value: value, page: page) {
            SymbolTile(symbol: symbol, tint: tint, size: 22)
        }
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
            SettingsPaneHeader(pane: .general)

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
            }

            Section {
                Toggle("顯示選單列圖示", isOn: $showMenuBarIcon)
                    .disabled(isOnlyMenuBarIcon)
                Toggle("顯示 Dock 圖示", isOn: showsDockIcon)
                    .disabled(isOnlyDockIcon)
            }

            LanguageSection()
        }
        .formStyle(.grouped)
        // Turned on or off in System Settings › Login Items too, so it is
        // read again whenever the pane appears.
        .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
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
    /// gone there is nothing left to open Hamasen from.
    private var isOnlyMenuBarIcon: Bool { showMenuBarIcon && hideDockIcon }
    private var isOnlyDockIcon: Bool { !hideDockIcon && !showMenuBarIcon }

    private func applyLaunchAtLogin(_ isEnabled: Bool) {
        guard isEnabled != (SMAppService.mainApp.status == .enabled) else { return }
        do {
            if isEnabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            launchAtLoginError = String(localized: "無法變更登入啟動設定：\(error.localizedDescription)")
        }
    }
}

// MARK: - Notifications

/// Which events are worth a notification, and whether macOS lets any
/// through at all.
private struct NotificationSettingsView: View {
    let showsUpdates: Bool

    @AppStorage(AppNotifier.Kind.connectionProblems.defaultsKey) private var connectionProblems = true
    @AppStorage(AppNotifier.Kind.conflicts.defaultsKey) private var conflicts = true
    @AppStorage(AppNotifier.Kind.remoteChanges.defaultsKey) private var remoteChanges = false
    @AppStorage(AppNotifier.Kind.updates.defaultsKey) private var updates = true

    @State private var status: UNAuthorizationStatus = .authorized

    init(showsUpdates: Bool) {
        self.showsUpdates = showsUpdates
    }

    var body: some View {
        Form {
            SettingsPaneHeader(pane: .notifications)

            switch status {
            case .denied:
                Section {
                    LabeledContent("已在系統設定中關閉") {
                        Button("開啟系統設定") { openNotificationSettings() }
                    }
                }
            case .notDetermined:
                Section {
                    LabeledContent("尚未允許") {
                        Button("允許通知") {
                            Task {
                                await AppNotifier.requestAuthorization()
                                status = await AppNotifier.authorizationStatus()
                            }
                        }
                    }
                }
            default:
                EmptyView()
            }

            Section {
                Toggle("連線中斷或需要重新登入", isOn: $connectionProblems)
                Toggle("檔案衝突", isOn: $conflicts)
                Toggle("伺服器上的檔案有變更", isOn: $remoteChanges)
                if showsUpdates {
                    Toggle("有新版本", isOn: $updates)
                }
            }
            .disabled(status == .denied)
        }
        .formStyle(.grouped)
        .task { status = await AppNotifier.authorizationStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { status = await AppNotifier.authorizationStatus() }
        }
    }

    private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
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
            Text("Finder 右鍵選單跟隨系統語言。")
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

// MARK: - Advanced

/// Settings few people change, each group on a page of its own.
private struct AdvancedSettingsView: View {
    @AppStorage(AppSettings.Keys.connectTimeoutSeconds, store: AppSettings.sharedStore)
    private var connectTimeoutSeconds = AppSettings.defaultConnectTimeoutSeconds

    @AppStorage(AppSettings.Keys.debugLoggingEnabled, store: AppSettings.sharedStore)
    private var debugLoggingEnabled = false

    var body: some View {
        Form {
            SettingsPaneHeader(pane: .advanced)

            Section {
                SettingsNavigationRow(
                    title: String(localized: "連線"), symbol: "network", tint: .blue,
                    value: String(localized: "\(connectTimeoutSeconds) 秒"), page: .connectionDefaults)
                SettingsNavigationRow(
                    title: String(localized: "Spotlight 索引"), symbol: "magnifyingglass", tint: .gray,
                    page: .indexing)
                SettingsNavigationRow(
                    title: String(localized: "S3 上傳"), symbol: ServiceKind.s3.symbol, tint: ServiceKind.s3.tint,
                    page: .s3Upload)
            }

            Section {
                SettingsNavigationRow(
                    title: String(localized: "備份與匯入"), symbol: "clock.arrow.circlepath", tint: .green,
                    page: .backup)
                SettingsNavigationRow(
                    title: String(localized: "除錯記錄"), symbol: "ladybug.fill", tint: .gray,
                    value: debugLoggingEnabled ? String(localized: "開啟") : String(localized: "關閉"),
                    page: .debugLogging)
            }
        }
        .formStyle(.grouped)
    }
}

/// The configuration written out and read back, and bookmarks from other
/// apps.
private struct BackupPage: View {
    let model: ServerListModel

    var body: some View {
        AdvancedPage(title: String(localized: "備份與匯入")) {
            BackupSection(model: model)
            Section("書籤") {
                LabeledContent("Cyberduck 與 Mountain Duck") {
                    Button("匯入…") {
                        guard let files = BookmarkImporter.promptForBookmarks() else { return }
                        model.importBookmarks(from: files)
                    }
                }
            }
        }
    }
}

private struct DebugLoggingPage: View {
    @AppStorage(AppSettings.Keys.debugLoggingEnabled, store: AppSettings.sharedStore)
    private var debugLoggingEnabled = false

    var body: some View {
        AdvancedPage(title: String(localized: "除錯記錄")) {
            Section {
                Toggle("啟用除錯記錄", isOn: $debugLoggingEnabled)
            } footer: {
                Text("在 Console.app 以子系統 dev.hamasen 檢視記錄。App 與 File Provider 擴充功能都會套用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A page pushed from the advanced pane: its sections in a grouped form,
/// under the row's name.
private struct AdvancedPage<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .navigationTitle(title)
    }
}

/// How long a connection may take, and the port a new SFTP connection
/// starts with.
private struct ConnectionDefaultsPage: View {
    @AppStorage(AppSettings.Keys.connectTimeoutSeconds, store: AppSettings.sharedStore)
    private var connectTimeoutSeconds = AppSettings.defaultConnectTimeoutSeconds

    @AppStorage(AppSettings.Keys.defaultServerPort, store: AppSettings.sharedStore)
    private var defaultServerPort = ServerConfig.defaultSFTPPort

    var body: some View {
        AdvancedPage(title: String(localized: "連線")) {
            Section {
                Stepper(value: $connectTimeoutSeconds, in: AppSettings.connectTimeoutRange, step: 5) {
                    LabeledContent("連線逾時") {
                        Text("\(connectTimeoutSeconds) 秒")
                            .monospacedDigit()
                    }
                }
                TextField(
                    "新伺服器預設連接埠",
                    value: $defaultServerPort,
                    format: .number.grouping(.never)
                )
            }
        }
    }
}

/// How far the background walk goes so Spotlight can index what Finder has
/// not opened.
private struct IndexingSection: View {
    let model: ServerListModel

    @AppStorage(AppSettings.Keys.indexingDepth, store: AppSettings.sharedStore)
    private var depth = AppSettings.defaultIndexingDepth

    @AppStorage(AppSettings.Keys.indexingDirectoryLimit, store: AppSettings.sharedStore)
    private var directoryLimit = AppSettings.defaultIndexingDirectoryLimit

    @AppStorage(AppSettings.Keys.indexingItemLimit, store: AppSettings.sharedStore)
    private var itemLimit = AppSettings.defaultIndexingItemLimit

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
            set: { newValue in
                // The same rule the other way round: a threshold below one
                // part is raised to the first that is not, so the picker
                // shows the threshold the upload will use.
                thresholdBytes = newValue.rawValue >= partSizeBytes
                    ? newValue.rawValue
                    : S3MultipartThreshold.allCases.first { $0.rawValue >= partSizeBytes }?.rawValue
                        ?? partSizeBytes
            })
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

