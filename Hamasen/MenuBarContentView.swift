import AppKit
import HamasenCore
import SwiftUI

/// Menu bar dropdown: mount toggles per server plus quick actions.
/// Actions only — persistent preferences live in the Settings window.
struct MenuBarContentView: View {
    let model: ServerListModel

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if model.servers.isEmpty {
                Text("尚未新增伺服器")
            } else {
                ForEach(model.servers) { server in
                    Toggle(server.name, isOn: mountBinding(for: server))
                }
            }

            Divider()

            Button("在 Finder 中顯示") {
                Task { await model.revealInFinder() }
            }
            .disabled(model.mountedServerIDs.isEmpty)

            Button("開啟 Hamasen…") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }

            Divider()

            SettingsLink {
                Text("設定…")
            }
            .keyboardShortcut(",")

            Button("結束 Hamasen") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .task {
            await model.loadIfNeeded()
        }
    }

    private func mountBinding(for server: ServerConfig) -> Binding<Bool> {
        Binding(
            get: { model.isMounted(server) },
            set: { shouldMount in
                Task {
                    if shouldMount {
                        await model.mount(server)
                    } else {
                        await model.unmount(server)
                    }
                }
            }
        )
    }
}
