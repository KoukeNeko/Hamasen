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

/// How amounts and times read wherever transfers are listed. Nonisolated so
/// its functions can be passed to `map` from any context.
nonisolated enum TransferFormat {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        "\(bytes(Int64(bytesPerSecond)))/s"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(Int(seconds.rounded(.up)), 1))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
    }

    static func remaining(_ seconds: TimeInterval) -> String {
        let text = duration(seconds)
        return String(localized: "剩 \(text)")
    }

    /// "3 files · 2.1 MB/s" beside a list of files in flight.
    static func summary(count: Int, rate: Double) -> String {
        let files = String(localized: "\(count) 個檔案")
        return rate > 0 ? "\(files) · \(self.rate(rate))" : files
    }

    /// "3.2 MB / 7.1 MB", or what has moved so far while the size is unknown.
    static func amount(of transfer: TransferRecord) -> String {
        guard transfer.totalBytes > 0 else { return bytes(transfer.bytesTransferred) }
        return "\(bytes(transfer.bytesTransferred)) / \(bytes(transfer.totalBytes))"
    }

    /// "Home NAS · 3.2 MB / 7.1 MB · 1.2 MB/s · 3 s left", leaving out what
    /// is not known yet.
    static func detail(of transfer: TransferRecord, serverName: String, rate: Double?, remaining seconds: TimeInterval?) -> String {
        var parts = [serverName]
        if transfer.totalBytes > 0 { parts.append(amount(of: transfer)) }
        if let rate { parts.append(self.rate(rate)) }
        if let seconds { parts.append(remaining(seconds)) }
        return parts.joined(separator: " · ")
    }
}

extension TransferDirection {
    var symbol: String {
        switch self {
        case .upload: return "arrow.up"
        case .download: return "arrow.down"
        case .move: return "arrow.left.arrow.right"
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .upload: return "上傳"
        case .download: return "下載"
        case .move: return "移動"
        }
    }
}

/// One file in flight, compact, for the menu bar panel.
struct TransferRow: View {
    let transfer: TransferRecord
    let serverName: String
    let rate: Double?
    let remaining: TimeInterval?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            DirectionIcon(direction: transfer.direction)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(transfer.fileName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if transfer.totalBytes > 0 {
                        Text(transfer.fractionCompleted, format: .percent.precision(.fractionLength(0)))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                ProgressView(value: transfer.totalBytes > 0 ? transfer.fractionCompleted : nil)
                    .progressViewStyle(.linear)
                Text(TransferFormat.detail(of: transfer, serverName: serverName, rate: rate, remaining: remaining))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct DirectionIcon: View {
    let direction: TransferDirection

    var body: some View {
        Image(systemName: direction.symbol)
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
            .background(.quaternary, in: Circle())
            .accessibilityLabel(Text(direction.title))
    }
}

/// One transfer that finished, or failed.
struct CompletedTransferRow: View {
    let completed: CompletedTransfer
    let serverName: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: completed.failure == nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(completed.failure == nil ? Color.green : Color.red)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(completed.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: "\(serverName) · \(completed.finishedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .help(completed.failure ?? "")
        .accessibilityElement(children: .combine)
    }
}

/// A file both sides changed, and where this Mac's version went.
struct ConflictRow: View {
    let conflict: ConflictRecord
    let serverName: String
    let reveal: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.on.doc.fill")
                .foregroundStyle(.orange)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(conflict.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("另存為「\(conflict.copyName)」· \(serverName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Button("顯示", action: reveal)
                .controlSize(.small)
        }
        .accessibilityElement(children: .combine)
    }
}

/// What everything mounted holds on this Mac against the ceiling, if any.
struct LocalCopyUsageRow: View {
    let usage: CacheUsage
    let limit: Int64?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "internaldrive")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(usage.summary(against: limit))
                    .monospacedDigit()
                if let limit, limit > 0 {
                    ProgressView(value: min(Double(usage.totalBytes) / Double(limit), 1))
                        .tint(usage.exceeds(limit) ? .orange : .accentColor)
                }
            }
        }
    }
}

/// How the local copies read against a ceiling, wherever they are shown.
extension CacheUsage {
    func exceeds(_ limit: Int64?) -> Bool {
        guard let limit else { return false }
        return totalBytes > limit
    }

    /// "2.4 GB / 10 GB", or the amount alone with no ceiling.
    func summary(against limit: Int64?) -> String {
        guard let limit else { return TransferFormat.bytes(totalBytes) }
        return "\(TransferFormat.bytes(totalBytes)) / \(TransferFormat.bytes(limit))"
    }
}

/// A rounded panel on the window's background, for grouping rows outside a
/// form the way a grouped form does inside one.
struct Panel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}
