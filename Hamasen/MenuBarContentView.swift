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

/// The menu bar panel: how every connection is doing, what is moving, what
/// just finished or clashed, and the way into the app.
///
/// A window rather than a plain menu, because progress bars and usage
/// figures are not menu items.
struct MenuBarContentView: View {
    let model: ServerListModel
    let navigation: AppNavigation

    @Environment(\.openWindow) private var openWindow

    private static let width: CGFloat = 340
    /// Past this many connections the list scrolls rather than growing the
    /// panel taller than the screen.
    private static let maximumVisibleRows = 6

    private var transfers: [TransferRecord] { model.activity.transfers }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            connections
            if !transfers.isEmpty {
                Divider()
                section("傳輸中", detail: TransferFormat.summary(count: transfers.count, rate: model.activity.combinedRate)) {
                    ForEach(transfers.prefix(3)) { transfer in
                        TransferRow(
                            transfer: transfer, serverName: serverName(transfer.serverID),
                            rate: model.activity.currentRate(of: transfer),
                            remaining: model.activity.secondsRemaining(of: transfer))
                    }
                }
            }
            if !model.activity.recentConflicts.isEmpty {
                Divider()
                section("衝突") {
                    ForEach(model.activity.recentConflicts.prefix(3)) { conflict in
                        ConflictRow(conflict: conflict, serverName: serverName(conflict.serverID)) {
                            Task {
                                await model.revealItem(
                                    serverID: conflict.serverID,
                                    path: RemotePath.join(RemotePath.parent(of: conflict.path), conflict.copyName))
                            }
                        }
                    }
                }
            }
            if transfers.isEmpty, !model.activity.recentCompletions.isEmpty {
                Divider()
                section("最近完成") {
                    ForEach(model.activity.recentCompletions.prefix(3)) { completed in
                        CompletedTransferRow(completed: completed, serverName: serverName(completed.serverID))
                    }
                }
            }
            if !model.mountedServerIDs.isEmpty {
                Divider()
                HStack {
                    Text("本機複本")
                    Spacer()
                    Text(TransferFormat.bytes(model.cache.totalUsage.totalBytes))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            Divider()
            footer
        }
        .frame(width: Self.width)
        .task { await model.loadIfNeeded() }
        // The panel is often the only window open, so the figures it shows
        // have to keep themselves current.
        .refreshingCacheUsage(from: model)
    }

    private func serverName(_ id: UUID) -> String {
        model.servers.first { $0.id == id }?.name ?? ""
    }

    // MARK: - Header

    private var header: some View {
        let status = model.overallStatus
        return HStack(spacing: 10) {
            Image(systemName: status.headlineSymbol)
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(status.tint)
            Text(status.title)
                .font(.headline)
            Spacer()
        }
        .padding(14)
    }

    // MARK: - Connections

    @ViewBuilder
    private var connections: some View {
        if model.servers.isEmpty {
            MenuActionRow(title: "新增連線…", systemImage: "plus") { open(adding: true) }
                .padding(.vertical, 4)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.servers) { server in
                        MenuConnectionRow(server: server, status: model.status(for: server)) {
                            open(.connection(server.id))
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            // An exact height, not a maximum: a scroll view has no height of
            // its own, and the panel sizes itself to its contents.
            .frame(height: CGFloat(min(model.servers.count, Self.maximumVisibleRows)) * MenuConnectionRow.height + 8)
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func section<Content: View>(
        _ title: LocalizedStringKey, detail: String? = nil, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.caption.weight(.semibold))
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .monospacedDigit()
                }
            }
            .foregroundStyle(.secondary)
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            MenuActionRow(title: "在 Finder 中顯示", systemImage: "folder") {
                Task { await model.revealInFinder() }
            }
            .disabled(model.mountedServerIDs.isEmpty)

            MenuActionRow(title: "開啟 \(AppInfo.displayName)", systemImage: "macwindow") { open(nil) }

            MenuActionRow(title: "設定…", systemImage: "gearshape") { open(.settings(.general)) }
                .keyboardShortcut(",")

            MenuActionRow(title: "結束 \(AppInfo.displayName)", systemImage: "power") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(.vertical, 4)
    }

    private func open(_ item: SidebarItem? = nil, adding: Bool = false) {
        if let item { navigation.selection = item }
        if adding { navigation.isAddingConnection = true }
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// One connection in the panel, opening it in the window when clicked.
private struct MenuConnectionRow: View {
    static let height: CGFloat = 44

    let server: ServerConfig
    let status: ConnectionStatus
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ServiceIcon(kind: server.serviceKind, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(server.name).lineLimit(1)
                    Text(status.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                ConnectionStatusIcon(status: status)
            }
            .padding(.horizontal, 14)
            .frame(height: Self.height)
            .contentShape(.rect)
            .background(isHovering ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(status.detail ?? "")
    }
}

/// A menu-like row, since a window-style panel inherits none of the
/// highlighting a real menu item has.
private struct MenuActionRow: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    init(title: LocalizedStringResource, systemImage: String, action: @escaping () -> Void) {
        self.title = String(localized: title)
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage).frame(width: 16)
                Text(title)
                Spacer()
            }
            .contentShape(.rect)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                isHovering && isEnabled ? Color.accentColor.opacity(0.18) : .clear,
                in: RoundedRectangle(cornerRadius: 5))
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
