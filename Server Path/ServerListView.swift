import ServerPathCore
import SwiftUI

/// Main window: the list of configured servers with mount controls.
struct ServerListView: View {
    @State private var model = ServerListModel()
    @State private var isShowingAddSheet = false
    @State private var serverBeingEdited: ServerConfig?

    var body: some View {
        Group {
            if model.servers.isEmpty {
                emptyState
            } else {
                serverList
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isShowingAddSheet = true
                } label: {
                    Label("新增伺服器", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $isShowingAddSheet) {
            ServerFormView(existingServer: nil) { config, password in
                Task { await model.saveServer(config, password: password) }
            }
        }
        .sheet(item: $serverBeingEdited) { server in
            ServerFormView(existingServer: server) { config, password in
                Task { await model.saveServer(config, password: password) }
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
        .task {
            await model.load()
        }
    }

    private var emptyState: some View {
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

    private var serverList: some View {
        List(model.servers) { server in
            ServerRowView(
                server: server,
                isMounted: model.isMounted(server),
                onToggleMount: {
                    Task {
                        if model.isMounted(server) {
                            await model.unmount(server)
                        } else {
                            await model.mount(server)
                        }
                    }
                },
                onEdit: { serverBeingEdited = server },
                onDelete: {
                    Task { await model.removeServer(server) }
                }
            )
        }
    }
}

private struct ServerRowView: View {
    let server: ServerConfig
    let isMounted: Bool
    let onToggleMount: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isMounted ? "externaldrive.fill.badge.checkmark" : "externaldrive")
                .font(.title2)
                .foregroundStyle(isMounted ? .green : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.headline)
                Text("\(server.username)@\(server.host):\(String(server.port))\(server.remotePath)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                onEdit()
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.bordered)
            .help("編輯")

            Button(isMounted ? "卸載" : "掛載", action: onToggleMount)
                .buttonStyle(.borderedProminent)
                .tint(isMounted ? .orange : .accentColor)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("編輯", action: onEdit)
            Divider()
            Button("刪除", role: .destructive, action: onDelete)
        }
    }
}

#Preview {
    ServerListView()
}
