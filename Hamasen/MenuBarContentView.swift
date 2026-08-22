import AppKit
import HamasenCore
import SwiftUI

/// The menu bar popover: what is mounted, what is transferring, and the few
/// actions worth reaching without opening the window.
///
/// A window rather than a plain menu, because the things worth showing here —
/// transfer progress, how much each server is holding — are not menu items.
/// The cost is that every row is drawn rather than inherited, which is why
/// the row styling lives in this file.
struct MenuBarContentView: View {
    let model: ServerListModel

    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private static let width: CGFloat = 320

    /// Taken from the bundle rather than written here: the display name is
    /// already localized (哈瑪星 / Hamasen), and duplicating it would make a
    /// second place for the two to disagree.
    private static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Hamasen"
    }
    /// Past this many servers the list scrolls rather than growing a popover
    /// taller than the screen.
    private static let maximumVisibleRows = 6

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            servers
            Divider()
            footer
        }
        .frame(width: Self.width)
        .task { await model.loadIfNeeded() }
        // The popover is often the only window open, so the figures it shows
        // have to keep themselves current.
        .refreshingCacheUsage(from: model)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(Self.appName).font(.headline)
                Spacer()
                Text(mountedSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TransferStatusView(monitor: model.transfers)
        }
        .padding(12)
    }

    private var mountedSummary: String {
        String(localized: "已掛載 \(model.mountedServerIDs.count) 台")
    }

    @ViewBuilder
    private var servers: some View {
        if model.servers.isEmpty {
            Text("尚未新增伺服器")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.servers) { server in
                        ServerRow(
                            server: server,
                            usage: model.cache.usage[server.id],
                            isMounted: model.isMounted(server),
                            toggle: { setMounted($0, for: server) }
                        )
                    }
                }
            }
            // An exact height, not a maximum: a scroll view has no height of
            // its own, and the popover sizes itself to its contents, so a
            // maximum alone collapses the whole list to nothing.
            .frame(height: CGFloat(min(model.servers.count, Self.maximumVisibleRows)) * ServerRow.height)
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            ActionRow(title: "在 Finder 中顯示", systemImage: "folder") {
                Task { await model.revealInFinder() }
            }
            .disabled(model.mountedServerIDs.isEmpty)

            ActionRow(title: "開啟 Hamasen…", systemImage: "macwindow") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }

            // A plain button rather than SettingsLink: the link opens the
            // window without making the app active, and this popover is
            // exactly where it is not.
            ActionRow(title: "設定…", systemImage: "gearshape") {
                openSettings.raisingTheApp()
            }
            .keyboardShortcut(",")

            ActionRow(title: "結束 Hamasen", systemImage: "power") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(.vertical, 4)
    }

    private func setMounted(_ shouldMount: Bool, for server: ServerConfig) {
        Task {
            if shouldMount {
                await model.mount(server)
            } else {
                await model.unmount(server)
            }
        }
    }
}

/// One server: what it is, how much of this Mac it is using, and its mount
/// switch.
private struct ServerRow: View {
    static let height: CGFloat = 52

    let server: ServerConfig
    let usage: CacheUsage?
    let isMounted: Bool
    let toggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .foregroundStyle(isMounted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(server.name).lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            // Labelled for VoiceOver even though the label is hidden; an
            // empty string would also become a catalog key.
            Toggle("掛載", isOn: Binding(get: { isMounted }, set: toggle))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
    }

    /// The address, or what it is holding once there is something to say —
    /// the address is on screen everywhere else, the size is not.
    private var subtitle: String {
        guard isMounted, let usage, usage.totalBytes > 0 else {
            return "\(server.username)@\(server.host)"
        }
        return ByteCountFormatter.string(fromByteCount: usage.totalBytes, countStyle: .file)
    }
}

/// A menu-like row, since a window-style popover inherits none of the
/// highlighting a real menu item has.
private struct ActionRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Label(title: title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .background(isHovering && isEnabled ? Color.accentColor.opacity(0.15) : .clear)
        .onHover { isHovering = $0 }
    }

    struct Label: View {
        let title: LocalizedStringKey
        let systemImage: String

        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: systemImage).frame(width: 16)
                Text(title)
                Spacer()
            }
            .contentShape(.rect)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }
}
