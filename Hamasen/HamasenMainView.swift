import HamasenCore
import SwiftUI

/// Main window: site-manager layout with a server sidebar and a detail pane.
struct HamasenMainView: View {
    let model: ServerListModel

    @State private var selectedServerID: UUID?
    @State private var isShowingAddSheet = false

    private var selectedServer: ServerConfig? {
        model.servers.first { $0.id == selectedServerID }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
                .safeAreaInset(edge: .bottom) {
                    TransferStatusView(monitor: model.transfers)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
        } detail: {
            detail
        }
        .frame(minWidth: 780, minHeight: 480)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isShowingAddSheet = true
                } label: {
                    Label("新增伺服器", systemImage: "plus")
                }
                .help("新增伺服器")
            }
        }
        .sheet(isPresented: $isShowingAddSheet) {
            ServerFormView(existingServer: nil) { config, credentials in
                Task {
                    await model.saveServer(config, credentials: credentials)
                    selectedServerID = config.id
                }
            }
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
            if selectedServerID == nil {
                selectedServerID = model.servers.first?.id
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedServerID) {
            Section("伺服器") {
                ForEach(model.servers) { server in
                    ServerSidebarRow(server: server, isMounted: model.isMounted(server))
                        .tag(server.id)
                        .contextMenu {
                            Button(model.isMounted(server) ? "卸載" : "掛載") {
                                Task {
                                    if model.isMounted(server) {
                                        await model.unmount(server)
                                    } else {
                                        await model.mount(server)
                                    }
                                }
                            }
                            Divider()
                            Button("刪除", role: .destructive) {
                                Task {
                                    await model.removeServer(server)
                                    if selectedServerID == server.id {
                                        selectedServerID = nil
                                    }
                                }
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.servers.isEmpty {
                ContentUnavailableView {
                    Label("尚未新增伺服器", systemImage: "externaldrive.badge.wifi")
                } description: {
                    Text("新增 SFTP 伺服器後即可掛載到 Finder")
                } actions: {
                    Button("新增伺服器") {
                        isShowingAddSheet = true
                    }
                }
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let server = selectedServer {
            ServerDetailView(
                server: server,
                isMounted: model.isMounted(server),
                model: model,
                onDeleted: { selectedServerID = nil }
            )
            .id(server.id)
        } else {
            ContentUnavailableView {
                Label("選擇一台伺服器", systemImage: "sidebar.left")
            } description: {
                Text(model.servers.isEmpty
                    ? "從工具列的＋新增第一台伺服器"
                    : "從左側清單選擇伺服器以檢視與編輯設定")
            }
        }
    }
}

/// One server in the sidebar: mounted-status dot, name, and connection
/// summary.
private struct ServerSidebarRow: View {
    let server: ServerConfig
    let isMounted: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "externaldrive.fill")
                .foregroundStyle(isMounted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(server.name)
                    .lineLimit(1)
                Text("\(server.username)@\(server.host)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if isMounted {
                Circle()
                    .fill(.green)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel("已掛載")
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    HamasenMainView(model: ServerListModel())
}
