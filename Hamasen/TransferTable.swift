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
import UniformTypeIdentifiers

/// The files in flight, in the order they started, above the most recent
/// that finished or failed, newest first. A transfer keeps its row's
/// identity when it finishes, so a selected one stays selected. Double-
/// clicking a row, or its context menu, opens the details.
struct TransferTable: View {
    let transfers: [TransferRecord]
    let completions: [CompletedTransfer]
    let activity: ActivityMonitor
    let serverName: (UUID) -> String
    @Binding var selection: UUID?
    let showDetails: () -> Void
    let reveal: (_ serverID: UUID, _ path: String) -> Void

    private enum Row: Identifiable {
        case running(TransferRecord)
        case finished(CompletedTransfer)

        var id: UUID {
            switch self {
            case .running(let transfer): return transfer.id
            case .finished(let completed): return completed.id
            }
        }

        var serverID: UUID {
            switch self {
            case .running(let transfer): return transfer.serverID
            case .finished(let completed): return completed.serverID
            }
        }

        var path: String {
            switch self {
            case .running(let transfer): return transfer.path
            case .finished(let completed): return completed.path
            }
        }

        var fileName: String { RemotePath.name(of: path) }

        var direction: TransferDirection {
            switch self {
            case .running(let transfer): return transfer.direction
            case .finished(let completed): return completed.direction
            }
        }
    }

    private var rows: [Row] {
        // The record can hold a finished entry for a transfer that is still
        // listed as running for a moment; the running one is current.
        let running = Set(transfers.map(\.id))
        return transfers.map(Row.running) + completions.filter { !running.contains($0.id) }.map(Row.finished)
    }

    var body: some View {
        let rows = self.rows
        ScrollViewReader { proxy in
            // A column set that changes with the width is sized wrongly:
            // the table sizes a column only when it is added. So the columns
            // are fixed, and their ideal widths add up to what fits at the
            // window's default size; beside the inspector they shrink toward
            // their minimums, and past those the table scrolls sideways
            // rather than cut the name to its icon. The connection has no
            // column; the name's tooltip and the inspector give it.
            Table(rows, selection: $selection) {
                TableColumn("名稱") { row in
                    name(of: row)
                }
                .width(min: 80, ideal: 120)
                TableColumn("狀態") { row in
                    status(of: row)
                }
                .width(min: 48, ideal: 96, max: 180)
                TableColumn("大小") { row in
                    size(of: row)
                }
                .width(min: 40, ideal: 96, max: 160)
                TableColumn("速度") { row in
                    if case .running(let transfer) = row {
                        Text(activity.currentRate(of: transfer).map(TransferFormat.rate) ?? "—")
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
                .width(min: 36, ideal: 64, max: 96)
                TableColumn("時間") { row in
                    time(of: row)
                }
                .width(min: 36, ideal: 90, max: 150)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView("沒有傳輸", systemImage: "arrow.up.arrow.down")
                }
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                    Button("詳細資訊") {
                        selection = id
                        showDetails()
                    }
                    Button("在 Finder 中顯示") { reveal(row.serverID, row.path) }
                }
            } primaryAction: { ids in
                guard let id = ids.first else { return }
                selection = id
                showDetails()
            }
            // A selected transfer that finishes moves from the running rows
            // to the top of the finished ones; keep it in view.
            .onChange(of: transfers.map(\.id)) { old, new in
                guard let selection, old.contains(selection), !new.contains(selection) else { return }
                proxy.scrollTo(selection)
            }
        }
    }

    private func name(of row: Row) -> some View {
        let connection = serverName(row.serverID)
        return HStack(spacing: 6) {
            FileIcon(name: row.fileName, size: 16)
            Text(row.fileName)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help(Text(verbatim: "\(connection) · \(row.path)"))
        .accessibilityValue(connection)
    }

    private func status(of row: Row) -> some View {
        HStack(spacing: 6) {
            Image(systemName: row.direction.symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text(row.direction.title))
            switch row {
            case .running(let transfer):
                // Too narrow for a readable bar beside the inspector, the
                // percentage alone says more.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        ProgressView(value: transfer.totalBytes > 0 ? transfer.fractionCompleted : nil)
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                            .frame(minWidth: 40)
                        percent(of: transfer)
                    }
                    percent(of: transfer)
                }
            case .finished(let completed):
                if let failure = completed.failure {
                    Label("失敗", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .help(failure)
                        .accessibilityValue(failure)
                } else {
                    Text("已完成")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private func percent(of transfer: TransferRecord) -> some View {
        if transfer.totalBytes > 0 {
            Text(transfer.fractionCompleted, format: .percent.precision(.fractionLength(0)))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 34, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func size(of row: Row) -> some View {
        switch row {
        case .running(let transfer):
            Text(TransferFormat.amount(of: transfer))
                .monospacedDigit()
                .lineLimit(1)
        case .finished(let completed):
            if completed.totalBytes > 0 {
                Text(TransferFormat.bytes(completed.totalBytes))
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
    }

    /// Time left while a transfer runs, when it ended once it has. Each says
    /// which it is to VoiceOver, since they share a column.
    @ViewBuilder
    private func time(of row: Row) -> some View {
        switch row {
        case .running(let transfer):
            let remaining = activity.secondsRemaining(of: transfer)
            Text(remaining.map(TransferFormat.remaining) ?? "—")
                .monospacedDigit()
                .lineLimit(1)
                .accessibilityLabel(Text("剩餘時間"))
                .accessibilityValue(remaining.map(TransferFormat.duration) ?? "—")
        case .finished(let completed):
            let finished = Self.finishTime(completed.finishedAt)
            Text(finished)
                .monospacedDigit()
                .lineLimit(1)
                .accessibilityLabel(Text("完成時間"))
                .accessibilityValue(finished)
        }
    }

    private static let earlierDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    /// "2:02 PM" today, "Yesterday 6:05 PM" or a date before that.
    private static func finishTime(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : earlierDayFormatter.string(from: date)
    }
}

/// Everything known about one transfer: the selected one while it runs, and
/// how it ended once it has.
struct TransferInspector: View {
    let transfer: TransferRecord?
    let completed: CompletedTransfer?
    let serverName: String
    let rate: Double?
    let remaining: TimeInterval?
    /// Measured against the activity record's last read, so it moves while
    /// the transfer does.
    let elapsed: TimeInterval?
    let reveal: () -> Void

    var body: some View {
        if let transfer {
            running(transfer)
        } else if let completed {
            finished(completed)
        } else {
            ContentUnavailableView("未選取傳輸", systemImage: "arrow.up.arrow.down")
        }
    }

    private func running(_ transfer: TransferRecord) -> some View {
        Form {
            Section {
                header(name: transfer.fileName)
            }
            Section {
                ProgressView(value: transfer.totalBytes > 0 ? transfer.fractionCompleted : nil)
                LabeledContent("已傳輸", value: TransferFormat.amount(of: transfer))
                LabeledContent("速度", value: rate.map(TransferFormat.rate) ?? "—")
                LabeledContent("平均速度", value: transfer.bytesPerSecond.map(TransferFormat.rate) ?? "—")
                LabeledContent("剩餘時間", value: remaining.map(TransferFormat.duration) ?? "—")
            }
            Section {
                details(serverID: transfer.serverID, path: transfer.path, direction: transfer.direction)
                LabeledContent("開始時間", value: transfer.startedAt.formatted(date: .omitted, time: .standard))
                if let elapsed {
                    LabeledContent("經過時間", value: TransferFormat.duration(elapsed))
                }
            }
            Section {
                Button("在 Finder 中顯示", action: reveal)
            }
        }
        .formStyle(.grouped)
        .monospacedDigit()
    }

    private func finished(_ completed: CompletedTransfer) -> some View {
        Form {
            Section {
                header(name: completed.fileName)
            }
            Section {
                if let failure = completed.failure {
                    LabeledContent("狀態", value: String(localized: "失敗"))
                    Text(failure)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    LabeledContent("狀態", value: String(localized: "已完成"))
                }
                if completed.totalBytes > 0 {
                    LabeledContent("大小", value: TransferFormat.bytes(completed.totalBytes))
                }
                LabeledContent("完成時間", value: completed.finishedAt.formatted(date: .omitted, time: .standard))
            }
            Section {
                details(serverID: completed.serverID, path: completed.path, direction: completed.direction)
            }
            Section {
                Button("在 Finder 中顯示", action: reveal)
            }
        }
        .formStyle(.grouped)
        .monospacedDigit()
    }

    private func header(name: String) -> some View {
        HStack(spacing: 12) {
            FileIcon(name: name, size: 40)
            Text(name)
                .font(.headline)
                .lineLimit(3)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func details(serverID: UUID, path: String, direction: TransferDirection) -> some View {
        LabeledContent("連線", value: serverName)
        LabeledContent("位置") {
            Text(RemotePath.parent(of: path))
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        LabeledContent("方向") {
            Text(direction.title)
        }
    }
}

/// The icon Finder shows for a file of this name's type.
struct FileIcon: View {
    let name: String
    let size: CGFloat

    var body: some View {
        let type = UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
        Image(nsImage: NSWorkspace.shared.icon(for: type))
            .resizable()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
