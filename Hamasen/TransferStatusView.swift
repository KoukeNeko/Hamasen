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

import SwiftUI

/// Shows what is transferring, and nothing at all when nothing is.
///
/// A row that is always present but usually empty reads as broken; a row that
/// appears only while there is something to say does not.
struct TransferStatusView: View {
    let monitor: TransferMonitor

    var body: some View {
        if monitor.isTransferring {
            VStack(alignment: .leading, spacing: 6) {
                if monitor.downloads.isActive {
                    row(
                        title: "正在下載",
                        systemImage: "arrow.down.circle",
                        activity: monitor.downloads
                    )
                }
                if monitor.uploads.isActive {
                    row(
                        title: "正在上傳",
                        systemImage: "arrow.up.circle",
                        activity: monitor.uploads
                    )
                }
            }
        }
    }

    private func row(
        title: LocalizedStringKey,
        systemImage: String,
        activity: TransferMonitor.Activity
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(title)
                Spacer()
                Text(Self.transferred(activity))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.caption)

            ProgressView(value: activity.fractionCompleted)
                .progressViewStyle(.linear)
        }
    }

    /// "3.2 MB / 40 MB", or just the file count while the total is unknown —
    /// a transfer whose size the server has not reported yet.
    private static func transferred(_ activity: TransferMonitor.Activity) -> String {
        guard activity.totalBytes > 0 else {
            return String(
                AttributedString(localized: "\(activity.fileCount) 個項目").characters
            )
        }
        let completed = ByteCountFormatter.string(fromByteCount: activity.completedBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: activity.totalBytes, countStyle: .file)
        return "\(completed) / \(total)"
    }
}
