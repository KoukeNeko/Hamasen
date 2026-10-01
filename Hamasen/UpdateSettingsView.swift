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

/// Whether a newer release is out, for builds the App Store does not update.
struct UpdateSettingsView: View {
    let updates: UpdateChecker

    @AppStorage(UpdateChecker.automaticChecksKey) private var checksAutomatically = true

    var body: some View {
        Form {
            SettingsPaneHeader(pane: .updates)
            Section {
                LabeledContent("目前版本") {
                    Text(verbatim: "\(AppInfo.version) (\(AppInfo.build))")
                        .monospacedDigit()
                        .textSelection(.enabled)
                }
                Toggle("自動檢查更新", isOn: $checksAutomatically)
            }
            Section {
                LabeledContent {
                    switch updates.state {
                    case .checking:
                        ProgressView().controlSize(.small)
                    case .available(let release):
                        Button("下載") { updates.download(release) }
                            .buttonStyle(.borderedProminent)
                    default:
                        Button("立即檢查") { Task { await updates.check() } }
                    }
                } label: {
                    status
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var status: some View {
        switch updates.state {
        case .idle:
            if let lastChecked = updates.lastChecked {
                Text("上次檢查：\(lastChecked.formatted(date: .abbreviated, time: .shortened))")
            } else {
                Text("尚未檢查")
            }
        case .checking:
            Text("檢查中…")
        case .upToDate:
            Text("已是最新版本")
        case .available(let release):
            Text("\(AppInfo.displayName) \(release.version) 已推出")
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .lineLimit(2)
        }
    }
}
