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
import SwiftUI

/// How much of this Mac the mounted connections use, and the rules that
/// keep it in check.
struct StorageSettingsView: View {
    let model: ServerListModel

    @AppStorage(AppSettings.Keys.autoCleanEnabled, store: AppSettings.sharedStore)
    private var isAutoCleanEnabled = true

    @AppStorage(AppSettings.Keys.autoCleanUnusedDays, store: AppSettings.sharedStore)
    private var unusedDays = AppSettings.defaultAutoCleanUnusedDays

    @AppStorage(AppSettings.Keys.autoCleanTotalLimitBytes, store: AppSettings.sharedStore)
    private var totalLimitBytes = Int(AppSettings.defaultAutoCleanTotalLimitBytes)

    @State private var isCleaning = false
    @State private var isConfirmingRemoval = false
    @State private var isConfirmingReset = false
    @State private var isResetting = false

    private var limit: AutoCleanTotalLimit { AutoCleanTotalLimit(bytes: Int64(totalLimitBytes)) }

    var body: some View {
        Form {
            SettingsPaneHeader(pane: .storage)

            Section("目前用量") {
                LocalCopyUsageRow(usage: model.cache.totalUsage, limit: isAutoCleanEnabled ? limit.bytes : nil)
                    .padding(.vertical, 2)
                HStack {
                    Button("立即清理") { run { await model.cache.cleanNow() } }
                    Button("移除全部下載…", role: .destructive) { isConfirmingRemoval = true }
                    Spacer()
                    if isCleaning { ProgressView().controlSize(.small) }
                }
                .disabled(isCleaning || model.mountedServerIDs.isEmpty)
            }

            Section("自動清理") {
                Toggle("自動清理", isOn: $isAutoCleanEnabled)
                    .onChange(of: isAutoCleanEnabled) { model.cache.sweepSoon() }
                Picker("閒置後移除", selection: unusedDaysSelection) {
                    ForEach(AutoCleanUnusedDays.allCases) { days in
                        Text(days.displayName).tag(days)
                    }
                }
                .disabled(!isAutoCleanEnabled)
                Picker("總量上限", selection: limitSelection) {
                    ForEach(AutoCleanTotalLimit.allCases) { limit in
                        Text(limit.displayName).tag(limit)
                    }
                }
                .disabled(!isAutoCleanEnabled)
            }

            if !model.mountedServerIDs.isEmpty {
                Section("各連線") {
                    ForEach(model.servers.filter(model.isMounted)) { server in
                        LabeledContent {
                            Text(TransferFormat.bytes(model.cache.usage[server.id]?.totalBytes ?? 0))
                                .monospacedDigit()
                        } label: {
                            Label {
                                Text(server.name)
                            } icon: {
                                ServiceIcon(kind: server.serviceKind, size: 18)
                            }
                        }
                    }
                }
            }

            // Last: it is the way out of a broken location, not part of
            // managing space.
            Section {
                HStack {
                    Button("重設 Finder 位置…", role: .destructive) { isConfirmingReset = true }
                        .confirmationDialog("重設 Finder 位置？", isPresented: $isConfirmingReset, titleVisibility: .visible) {
                            Button("重設", role: .destructive) { reset() }
                            Button("取消", role: .cancel) {}
                        } message: {
                            Text("這台 Mac 上的複本和尚未上傳的變更都會刪除。伺服器上的檔案不受影響。")
                        }
                    Spacer()
                    if isResetting { ProgressView().controlSize(.small) }
                }
                .disabled(isResetting || isCleaning)
            }
        }
        .formStyle(.grouped)
        .refreshingCacheUsage(from: model)
        .confirmationDialog("移除全部下載？", isPresented: $isConfirmingRemoval, titleVisibility: .visible) {
            Button("移除", role: .destructive) { run { await model.cache.removeAllDownloads() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("檔案仍會顯示在 Finder，下次開啟時重新下載。保留在這台 Mac、尚未上傳完成或正在使用的檔案不會移除。")
        }
    }

    private var unusedDaysSelection: Binding<AutoCleanUnusedDays> {
        Binding(
            get: { AutoCleanUnusedDays(days: unusedDays) },
            set: {
                unusedDays = $0.rawValue
                model.cache.sweepSoon()
            })
    }

    private var limitSelection: Binding<AutoCleanTotalLimit> {
        Binding(
            get: { limit },
            set: {
                totalLimitBytes = Int($0.rawValue)
                model.cache.sweepSoon()
            })
    }

    private func reset() {
        isResetting = true
        Task {
            await model.resetFinderLocation()
            await model.cache.refreshUsage()
            isResetting = false
        }
    }

    private func run(_ work: @escaping () async -> Void) {
        isCleaning = true
        Task {
            await work()
            await model.cache.refreshUsage()
            isCleaning = false
        }
    }
}
