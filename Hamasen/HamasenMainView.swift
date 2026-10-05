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

/// What the sidebar can show in the detail pane.
extension LocalizedStringResource {
    /// Chinese says 連線 for one connection or many, so a heading over
    /// several needs a key of its own for languages that tell them apart.
    static let connectionsHeading = LocalizedStringResource(
        "connections.heading", defaultValue: "連線",
        comment: "Heading over a list or a count of connections")
}

enum SidebarItem: Hashable {
    case overview
    case gettingStarted
    case connection(UUID)
    case settings(SettingsPane)
}

/// The main window, laid out like System Settings: a sidebar with the
/// overview, every connection and the settings panes, and the selected one
/// beside it.
struct HamasenMainView: View {
    let model: ServerListModel
    let guide: GettingStarted
    @Bindable var navigation: AppNavigation

    @State private var pendingDeletion: ServerConfig?
    @State private var searchText = ""

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 340)
                // The sidebar is the window's navigation and stays; ⌃⌘S and
                // View › Hide Sidebar still hide it for anyone who wants to.
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                .historyToolbar()
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: Text("搜尋"))
        .environment(navigation)
        .frame(minWidth: 860, minHeight: 560)
        .sheet(isPresented: $navigation.isAddingConnection) {
            AddConnectionSheet(model: model) { id in navigation.selection = .connection(id) }
                .environment(navigation)
        }
        .alert(
            "發生錯誤",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("確定", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert(
            model.notice?.title ?? "",
            isPresented: Binding(
                get: { model.notice != nil },
                set: { if !$0 { model.notice = nil } }
            )
        ) {
            Button("確定", role: .cancel) {}
        } message: {
            Text(model.notice?.message ?? "")
        }
        .task {
            await model.loadIfNeeded()
            await guide.refresh()
            if navigation.selection == nil {
                navigation.selection = showsGettingStarted ? .gettingStarted : .overview
            }
        }
        .confirmationDialog(
            "刪除「\(pendingDeletion?.name ?? "")」？",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { server in
            Button("刪除", role: .destructive) { Task { await model.removeServer(server) } }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("連線會從 Finder 移除，儲存的登入資訊也會刪除。伺服器上的檔案不受影響。")
        }
        .onChange(of: model.servers.map(\.id)) { _, ids in
            // A connection deleted from anywhere — the menu bar, a backup
            // restore — must not leave its pane open.
            if case .connection(let id) = navigation.selection, !ids.contains(id) {
                navigation.selection = .overview
            }
        }
    }

    private var showsGettingStarted: Bool {
        !guide.isDismissed && !guide.isComplete(model: model)
    }

    // MARK: - Sidebar

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var query: String { searchText.trimmingCharacters(in: .whitespaces) }

    private var visibleServers: [ServerConfig] {
        guard isSearching else { return model.servers }
        return model.servers.filter {
            $0.name.localizedStandardContains(query) || $0.addressSummary.localizedStandardContains(query)
                || $0.serviceKind.title.localizedStandardContains(query)
        }
    }

    private var visiblePanes: [SettingsPane] {
        SettingsPane.allCases.filter { pane in
            (pane != .updates || model.updates.isAvailable) && (!isSearching || pane.matches(query))
        }
    }

    private var sidebar: some View {
        List(selection: $navigation.selection) {
            if !isSearching {
                Section {
                    SidebarLabel(title: String(localized: "總覽"), symbol: "square.grid.2x2.fill", tint: .blue)
                        .tag(SidebarItem.overview)
                    if showsGettingStarted {
                        SidebarLabel(title: String(localized: "開始使用"), symbol: "checklist", tint: .green)
                            .tag(SidebarItem.gettingStarted)
                    }
                }
            }

            if !visibleServers.isEmpty || !isSearching {
                Section {
                    ForEach(visibleServers) { server in
                        ConnectionSidebarRow(server: server, status: model.status(for: server))
                            .tag(SidebarItem.connection(server.id))
                            .contextMenu { contextMenu(for: server) }
                    }
                    .onMove(perform: isSearching ? nil : { source, destination in
                        model.moveServers(fromOffsets: source, toOffset: destination)
                    })
                } header: {
                    HStack {
                        Text(.connectionsHeading)
                        Spacer()
                        Button {
                            navigation.isAddingConnection = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless)
                        .help("新增連線")
                        .accessibilityLabel(Text("新增連線"))
                        // A sidebar header reaches further right than its
                        // rows; inset to sit in the status icons' column.
                        .padding(.trailing, SidebarMetrics.headerTrailingInset)
                    }
                }
            }

            if !visiblePanes.isEmpty {
                Section("設定") {
                    ForEach(visiblePanes) { pane in
                        SidebarLabel(title: pane.title, symbol: pane.symbol, tint: pane.tint)
                            .tag(SidebarItem.settings(pane))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if isSearching, visibleServers.isEmpty, visiblePanes.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for server: ServerConfig) -> some View {
        Button("在 Finder 中顯示") { Task { await model.revealInFinder(server) } }
            .disabled(!model.isMounted(server))
        if model.isMounted(server) {
            Button(server.isPaused ? "繼續同步" : "暫停同步") {
                Task { await model.setPaused(!server.isPaused, for: server) }
            }
            Button("從 Finder 卸載") { Task { await model.unmount(server) } }
        } else {
            Button("掛載到 Finder") { Task { await model.mount(server) } }
        }
        Divider()
        Button("刪除…", role: .destructive) { pendingDeletion = server }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch navigation.selection {
        case .connection(let id):
            if let server = model.servers.first(where: { $0.id == id }) {
                ConnectionDetailView(server: server, model: model) { navigation.selection = .overview }
                    .id(server.id)
            } else {
                overview
            }
        case .gettingStarted:
            GettingStartedView(
                model: model, guide: guide,
                onAddConnection: { navigation.isAddingConnection = true },
                onFinish: { navigation.selection = .overview })
        case .settings(let pane):
            SettingsPaneView(pane: pane, model: model)
                .id(pane)
        case .overview, nil:
            overview
        }
    }

    @ViewBuilder
    private var overview: some View {
        if model.servers.isEmpty {
            ContentUnavailableView {
                Label("沒有連線", systemImage: "externaldrive.badge.plus")
            } actions: {
                Button("新增連線") { navigation.isAddingConnection = true }
                    .buttonStyle(.borderedProminent)
                Button("匯入書籤…", action: importBookmarks)
            }
            .navigationTitle("總覽")
        } else {
            OverviewView(model: model, onSelect: select, onAdd: { navigation.isAddingConnection = true })
        }
    }

    private func select(_ id: UUID) {
        navigation.selection = .connection(id)
    }

    /// The panel is what grants a sandboxed app access to the chosen files,
    /// so the import always starts from it.
    private func importBookmarks() {
        guard let files = BookmarkImporter.promptForBookmarks() else { return }
        model.importBookmarks(from: files)
    }
}

/// One connection in the sidebar: its icon, its name, and how it is doing.
private struct ConnectionSidebarRow: View {
    let server: ServerConfig
    let status: ConnectionStatus

    var body: some View {
        HStack(spacing: 8) {
            Label {
                Text(server.name).lineLimit(1)
            } icon: {
                ServiceIcon(kind: server.serviceKind, size: 20)
            }
            Spacer(minLength: 4)
            ConnectionStatusIcon(status: status)
                .font(.callout)
        }
    }
}

/// A sidebar row with a tinted icon, as System Settings draws its own.
private struct SidebarLabel: View {
    let title: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label {
            Text(title)
        } icon: {
            SymbolTile(symbol: symbol, tint: tint, size: 20)
        }
    }
}

extension View {
    /// Back and forward, as System Settings has them: through the panes
    /// visited and the pages opened within them.
    ///
    /// Declared once around the detail column and present on every pane, so
    /// the toolbar keeps one height and one set of controls whatever is
    /// selected.
    func historyToolbar() -> some View {
        modifier(HistoryToolbar())
    }
}

private struct HistoryToolbar: ViewModifier {
    @Environment(AppNavigation.self) private var navigation

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .navigation) {
                ControlGroup {
                    Button {
                        navigation.goBack()
                    } label: {
                        Label("返回", systemImage: "chevron.left")
                    }
                    .disabled(!navigation.canGoBack)
                    .help("返回")

                    Button {
                        navigation.goForward()
                    } label: {
                        Label("前進", systemImage: "chevron.right")
                    }
                    .disabled(!navigation.canGoForward)
                    .help("前進")
                }
                .controlGroupStyle(.navigation)
            }
        }
    }
}

private enum SidebarMetrics {
    static let headerTrailingInset: CGFloat = 15
}
