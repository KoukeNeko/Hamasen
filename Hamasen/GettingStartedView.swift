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
import ServiceManagement
import SwiftUI
import UserNotifications

/// The steps between installing Hamasen and using a server in Finder, each
/// checked off as it is done — most of them by watching the system rather
/// than by taking the person's word for it.
@MainActor
@Observable
final class GettingStarted {
    enum Step: Int, CaseIterable, Identifiable {
        case addConnection
        case enableInSystemSettings
        case allowNotifications
        case findInFinder
        case openAtLogin

        var id: Int { rawValue }
    }

    private static let skippedKey = "gettingStarted.skipped"
    private static let finishedKey = "gettingStarted.finished"

    private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined
    private(set) var opensAtLogin = SMAppService.mainApp.status == .enabled
    private(set) var skipped: Set<Int> = Set(UserDefaults.standard.array(forKey: skippedKey) as? [Int] ?? [])
    private(set) var hasFoundInFinder = UserDefaults.standard.bool(forKey: "gettingStarted.foundInFinder")

    /// Whether the guide was finished or put aside for good; it stays
    /// reachable from the Help menu either way.
    var isDismissed: Bool {
        get { UserDefaults.standard.bool(forKey: Self.finishedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.finishedKey) }
    }

    func refresh() async {
        notificationStatus = await AppNotifier.authorizationStatus()
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }

    func isDone(_ step: Step, model: ServerListModel) -> Bool {
        switch step {
        case .addConnection: return !model.servers.isEmpty
        case .enableInSystemSettings: return model.isDomainEnabled == true
        case .allowNotifications: return notificationStatus == .authorized || notificationStatus == .provisional
        case .findInFinder: return hasFoundInFinder
        case .openAtLogin: return opensAtLogin
        }
    }

    func isSkipped(_ step: Step) -> Bool { skipped.contains(step.rawValue) }

    func isSettled(_ step: Step, model: ServerListModel) -> Bool {
        isDone(step, model: model) || isSkipped(step)
    }

    /// The first step neither done nor skipped, which is the one that shows
    /// its actions.
    func current(model: ServerListModel) -> Step? {
        Step.allCases.first { !isSettled($0, model: model) }
    }

    func isComplete(model: ServerListModel) -> Bool { current(model: model) == nil }

    func skip(_ step: Step) {
        skipped.insert(step.rawValue)
        UserDefaults.standard.set(Array(skipped), forKey: Self.skippedKey)
    }

    func markFoundInFinder() {
        hasFoundInFinder = true
        UserDefaults.standard.set(true, forKey: "gettingStarted.foundInFinder")
    }

    func requestNotifications() async {
        await AppNotifier.requestAuthorization()
        await refresh()
    }

    func enableOpenAtLogin() throws {
        try SMAppService.mainApp.register()
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }
}

struct GettingStartedView: View {
    let model: ServerListModel
    let guide: GettingStarted
    let onAddConnection: () -> Void
    let onFinish: () -> Void

    @State private var loginItemError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 80, height: 80)
                    Text("歡迎使用 \(AppInfo.displayName)")
                        .font(.largeTitle.bold())
                }
                .multilineTextAlignment(.center)

                Panel {
                    ForEach(Array(GettingStarted.Step.allCases.enumerated()), id: \.element) { index, step in
                        if index > 0 { Divider().padding(.vertical, 12) }
                        row(step, number: index + 1)
                    }
                }
                .frame(maxWidth: 620)

                HStack {
                    if guide.isComplete(model: model) {
                        Button("開始使用") { finish() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    } else {
                        Button("稍後") { onFinish() }
                            .buttonStyle(.link)
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("開始使用")
        .task { await guide.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Coming back from System Settings is when a switch turned on
            // there should show up here.
            Task {
                await guide.refresh()
                await model.refreshDomainState()
            }
        }
    }

    private func finish() {
        guide.isDismissed = true
        onFinish()
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(_ step: GettingStarted.Step, number: Int) -> some View {
        let isDone = guide.isDone(step, model: model)
        let isCurrent = guide.current(model: model) == step
        HStack(alignment: .top, spacing: 14) {
            StepMarker(number: number, isDone: isDone, isCurrent: isCurrent)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(title(of: step))
                        .font(.headline)
                        .foregroundStyle(isDone || isCurrent ? .primary : .secondary)
                    if step == .openAtLogin {
                        Text("建議")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.green.opacity(0.15), in: Capsule())
                    }
                }
                if let state = state(of: step, isDone: isDone) {
                    Text(state)
                        .foregroundStyle(.secondary)
                }
                if isCurrent {
                    instructions(for: step)
                    actions(for: step)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func title(of step: GettingStarted.Step) -> LocalizedStringKey {
        switch step {
        case .addConnection: return "新增第一組連線"
        case .enableInSystemSettings: return "在系統設定中啟用"
        case .allowNotifications: return "允許通知"
        case .findInFinder: return "在 Finder 找到連線"
        case .openAtLogin: return "登入時啟動"
        }
    }

    /// What is already so, for a step that is done or skipped.
    private func state(of step: GettingStarted.Step, isDone: Bool) -> String? {
        if !isDone {
            return guide.isSkipped(step) ? String(localized: "已略過") : nil
        }
        switch step {
        case .addConnection:
            let name = model.servers.first?.name ?? ""
            return model.servers.count == 1
                ? String(localized: "已新增「\(name)」")
                : String(localized: "已新增 \(model.servers.count) 組連線")
        case .enableInSystemSettings, .openAtLogin: return String(localized: "已啟用")
        case .allowNotifications: return String(localized: "已允許")
        case .findInFinder: return String(localized: "已完成")
        }
    }

    @ViewBuilder
    private func instructions(for step: GettingStarted.Step) -> some View {
        switch step {
        case .enableInSystemSettings:
            Text("在「一般 › 登入項目與延伸功能」中，按「檔案供應商」旁的 ⓘ，開啟 \(AppInfo.displayName)。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .allowNotifications:
            Text("連線中斷、需要重新登入或檔案衝突時發出通知。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .findInFinder:
            Text("\(AppInfo.displayName) 位於 Finder 側邊欄的「位置」，每組連線是一個資料夾。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .openAtLogin:
            Text("登入後在背景掛載所有連線，並套用本機複本的清理設定。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .addConnection:
            EmptyView()
        }
    }

    @ViewBuilder
    private func actions(for step: GettingStarted.Step) -> some View {
        HStack(spacing: 12) {
            switch step {
            case .addConnection:
                Button("新增連線", action: onAddConnection)
                    .buttonStyle(.borderedProminent)
            case .enableInSystemSettings:
                Button("開啟系統設定") { model.openFileProviderSettings() }
                    .buttonStyle(.borderedProminent)
                if model.isDomainEnabled == nil {
                    // Nothing is mounted yet, so there is nothing to switch on.
                    Button("略過") { guide.skip(step) }
                        .buttonStyle(.link)
                }
            case .allowNotifications:
                if guide.notificationStatus == .denied {
                    Button("開啟系統設定") { openNotificationSettings() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("允許通知") { Task { await guide.requestNotifications() } }
                        .buttonStyle(.borderedProminent)
                }
                Button("略過") { guide.skip(step) }
                    .buttonStyle(.link)
            case .findInFinder:
                Button("在 Finder 中顯示") {
                    Task { await model.revealInFinder() }
                    guide.markFoundInFinder()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.mountedServerIDs.isEmpty)
                Button("略過") { guide.skip(step) }
                    .buttonStyle(.link)
            case .openAtLogin:
                Button("登入時啟動") {
                    do {
                        try guide.enableOpenAtLogin()
                        loginItemError = nil
                    } catch {
                        loginItemError = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
                Button("略過") { guide.skip(step) }
                    .buttonStyle(.link)
            }
        }
        if step == .openAtLogin, let loginItemError {
            Label(loginItemError, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }

    private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// A step's number, or a checkmark once it is done.
private struct StepMarker: View {
    let number: Int
    let isDone: Bool
    let isCurrent: Bool

    var body: some View {
        ZStack {
            if isDone {
                Circle().fill(.green)
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            } else if isCurrent {
                Circle().fill(Color.accentColor)
                Text(number, format: .number)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            } else {
                Circle().strokeBorder(.tertiary, lineWidth: 1.5)
                Text(number, format: .number)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }
}
