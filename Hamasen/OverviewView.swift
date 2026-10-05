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

/// Whether all is well and what needs a look, above every file moving or
/// lately moved. Connections are named only when one needs something; the
/// sidebar lists them all.
struct OverviewView: View {
    let model: ServerListModel
    let onSelect: (UUID) -> Void
    let onAdd: () -> Void

    @Environment(AppNavigation.self) private var navigation
    @State private var selectedTransfer: UUID?
    @State private var showsTransferDetails = false
    @State private var topContentHeight: CGFloat = 0

    /// The most of the page the summary takes before it scrolls, so the
    /// table keeps room however much needs attention.
    private static let topAreaShare: CGFloat = 0.6
    private static let padding: CGFloat = 20
    private static let visibleProblems = 3
    private static let visibleConflicts = 5

    private var transfers: [TransferRecord] { model.activity.transfers }

    var body: some View {
        // The pane's height is read here rather than measured into state: a
        // size fed back through state changes the page's minimum size, which
        // the split view answers by resizing the pane again, without end.
        GeometryReader { pane in
            VStack(spacing: 16) {
                // Exactly as tall as its content, and scrolling only past
                // the cap.
                ScrollView {
                    topArea
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topContentHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(topContentHeight, Self.topAreaShare * max(pane.size.height - 2 * Self.padding, 0)))
                TransferTable(
                    transfers: transfers,
                    completions: model.activity.recentCompletions,
                    activity: model.activity,
                    serverName: serverName,
                    selection: $selectedTransfer,
                    showDetails: { showsTransferDetails = true },
                    reveal: reveal(serverID:path:))
                .frame(maxHeight: .infinity)
            }
            .padding(Self.padding)
        }
        .navigationTitle("總覽")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await model.revealInFinder() }
                } label: {
                    Label("在 Finder 中顯示", systemImage: "folder")
                }
                .help("在 Finder 中顯示")
                .disabled(model.mountedServerIDs.isEmpty)
                Button(action: onAdd) {
                    Label("新增連線", systemImage: "plus")
                }
                .help("新增連線")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsTransferDetails.toggle()
                } label: {
                    Label("詳細資訊", systemImage: "info.circle")
                }
                .help("詳細資訊")
            }
        }
        .inspector(isPresented: $showsTransferDetails) {
            transferInspector
                .inspectorColumnWidth(min: 220, ideal: 240, max: 380)
        }
        .refreshingCacheUsage(from: model)
    }

    private func serverName(_ id: UUID) -> String {
        model.servers.first { $0.id == id }?.name ?? ""
    }

    private var topArea: some View {
        VStack(alignment: .leading, spacing: 16) {
            summary
            if !model.activity.recentConflicts.isEmpty { conflictsBox }
        }
    }

    // MARK: - Summary

    private var summary: some View {
        Panel {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                // First: with the location off, nothing below reaches Finder.
                if model.isDomainEnabled == false {
                    finderRow
                    Divider().gridCellUnsizedAxes(.horizontal)
                }
                connectionsRow
                if !model.mountedServerIDs.isEmpty {
                    Divider().gridCellUnsizedAxes(.horizontal)
                    localCopiesRow
                }
            }
        }
    }

    private var finderRow: some View {
        GridRow(alignment: .center) {
            Text(verbatim: "Finder")
            HStack {
                Label {
                    Text("已在系統設定中關閉")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 8)
                Button("開啟系統設定") { model.openFileProviderSettings() }
                    .controlSize(.small)
            }
        }
    }

    private var connectionsRow: some View {
        let problems = model.servers.filter { model.status(for: $0).needsAttention }
        return GridRow(alignment: .firstTextBaseline) {
            Text(.connectionsHeading)
            VStack(alignment: .leading, spacing: 10) {
                ConnectionCensus(statuses: model.servers.map(model.status(for:)))
                ForEach(problems.prefix(Self.visibleProblems)) { server in
                    Divider()
                    attentionRow(for: server)
                }
                if problems.count > Self.visibleProblems {
                    Divider()
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(problems.dropFirst(Self.visibleProblems)) { server in
                                Divider()
                                attentionRow(for: server)
                            }
                        }
                    } label: {
                        Text("另外 \(problems.count - Self.visibleProblems) 組連線")
                    }
                }
            }
        }
    }

    private func attentionRow(for server: ServerConfig) -> some View {
        AttentionRow(
            server: server,
            status: model.status(for: server),
            select: { onSelect(server.id) },
            reveal: { Task { await model.revealInFinder(server) } },
            pause: { Task { await model.setPaused(true, for: server) } })
    }

    private var localCopiesRow: some View {
        let usage = model.cache.totalUsage
        let limit = AppSettings.autoCleanPolicy()?.totalLimitBytes
        let isOver = usage.exceeds(limit)
        let summary = usage.summary(against: limit)
        return GridRow(alignment: .center) {
            Text("本機複本")
                .accessibilityHidden(true)
            Button {
                navigation.selection = .settings(.storage)
            } label: {
                HStack(spacing: 10) {
                    if let limit, limit > 0 {
                        ProgressView(value: min(Double(usage.totalBytes) / Double(limit), 1))
                            .progressViewStyle(.linear)
                            .tint(isOver ? .orange : .accentColor)
                            .frame(minWidth: 60, maxWidth: 140)
                    }
                    Text(summary)
                        .monospacedDigit()
                        .foregroundStyle(isOver ? Color.orange : Color.secondary)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            // What auto-clean cannot reclaim.
            .help(usage.pinnedBytes > 0 ? pinnedSplit(of: usage) : "")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("本機複本設定"))
            .accessibilityValue(summary)
        }
    }

    private func pinnedSplit(of usage: CacheUsage) -> String {
        let pinned = "\(String(localized: "保留")) \(TransferFormat.bytes(usage.pinnedBytes))"
        let cached = "\(String(localized: "快取")) \(TransferFormat.bytes(usage.evictableBytes))"
        return "\(pinned) · \(cached)"
    }

    // MARK: - Conflicts

    private var conflictsBox: some View {
        let conflicts = model.activity.recentConflicts
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("衝突")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("清除") { model.activity.clearConflicts() }
                    .buttonStyle(.link)
            }
            Panel {
                ForEach(Array(conflicts.prefix(Self.visibleConflicts).enumerated()), id: \.element.id) { index, conflict in
                    if index > 0 { conflictDivider }
                    conflictRow(conflict)
                }
                if conflicts.count > Self.visibleConflicts {
                    conflictDivider
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(conflicts.dropFirst(Self.visibleConflicts)) { conflict in
                                conflictDivider
                                conflictRow(conflict)
                            }
                        }
                    } label: {
                        Text("另外 \(conflicts.count - Self.visibleConflicts) 個衝突")
                    }
                }
            }
        }
    }

    /// Inset to the text, past the row's icon.
    private var conflictDivider: some View {
        Divider()
            .padding(.leading, 34)
            .padding(.vertical, 8)
    }

    private func conflictRow(_ conflict: ConflictRecord) -> some View {
        ConflictRow(conflict: conflict, serverName: serverName(conflict.serverID)) {
            // The copy, beside the original it was saved next to.
            reveal(serverID: conflict.serverID, path: RemotePath.join(RemotePath.parent(of: conflict.path), conflict.copyName))
        }
    }

    // MARK: - Transfers

    /// The selected transfer while it runs, and how it ended once it has —
    /// the selection outlives the row.
    private var transferInspector: some View {
        let transfer = transfers.first { $0.id == selectedTransfer }
        let completed = transfer == nil
            ? model.activity.recentCompletions.first { $0.id == selectedTransfer }
            : nil
        let serverID = transfer?.serverID ?? completed?.serverID
        let path = transfer?.path ?? completed?.path
        return TransferInspector(
            transfer: transfer,
            completed: completed,
            serverName: serverID.map(serverName) ?? "",
            rate: transfer.flatMap(model.activity.currentRate(of:)),
            remaining: transfer.flatMap(model.activity.secondsRemaining(of:)),
            elapsed: transfer.map { model.activity.lastRead.timeIntervalSince($0.startedAt) },
            reveal: {
                guard let serverID, let path else { return }
                reveal(serverID: serverID, path: path)
            })
    }

    private func reveal(serverID: UUID, path: String) {
        Task { await model.revealItem(serverID: serverID, path: path) }
    }
}

/// How many connections are in each state, problems first. Words give way
/// to symbols, then to a second line, as the room runs out.
private struct ConnectionCensus: View {
    let statuses: [ConnectionStatus]

    private struct Tally: Identifiable {
        let status: ConnectionStatus
        let count: Int
        var id: Int { status.rank }
    }

    var body: some View {
        let tallies = Dictionary(grouping: statuses, by: \.rank)
            .sorted { $0.key < $1.key }
            .map { Tally(status: $0.value[0], count: $0.value.count) }
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                ForEach(tallies) { item($0, titled: true) }
            }
            HStack(spacing: 10) {
                ForEach(tallies) { item($0, titled: false) }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    ForEach(tallies.prefix(3)) { item($0, titled: false) }
                }
                HStack(spacing: 10) {
                    ForEach(tallies.dropFirst(3)) { item($0, titled: false) }
                }
            }
        }
    }

    private func item(_ tally: Tally, titled: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: tally.status.symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tally.status.tint)
            if titled {
                Text(tally.status.title)
            }
            Text(tally.count, format: .number)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .help(titled ? Text(verbatim: "") : Text(tally.status.title))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(tally.status.title))
        .accessibilityValue(Text(tally.count, format: .number))
    }
}

/// A connection that needs something, with what it said, leading to its
/// page.
private struct AttentionRow: View {
    let server: ServerConfig
    let status: ConnectionStatus
    let select: () -> Void
    let reveal: () -> Void
    let pause: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                ServiceIcon(kind: server.serviceKind, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                        .lineLimit(1)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        ConnectionStatusLabel(status: status)
                            .fixedSize()
                        if let explanation = status.explanation {
                            Text(verbatim: "· \(explanation)")
                                .lineLimit(2)
                                .truncationMode(.tail)
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(status.explanation ?? "")
        .contextMenu {
            Button("在 Finder 中顯示", action: reveal)
            Button("暫停同步", action: pause)
        }
        .accessibilityAction(named: "在 Finder 中顯示", reveal)
        .accessibilityAction(named: "暫停同步", pause)
    }
}
