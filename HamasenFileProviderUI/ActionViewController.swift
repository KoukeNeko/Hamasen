import AppKit
import FileProvider
import FileProviderUI
import HamasenCore

/// Handles the custom Finder actions Hamasen adds to items inside a mount.
///
/// The system instantiates one of these per invocation, calls
/// `prepareForAction(withIdentifier:itemIdentifiers:)`, and shows it until the
/// request completes. None of the actions need input, so each one does its
/// work and shows a brief confirmation rather than a form.
final class ActionViewController: FPUIActionExtensionViewController {
    /// Identifiers declared in this extension's Info.plist.
    private enum Action: String {
        case copyRemotePath = "dev.hamasen.action.copyRemotePath"
        case refresh = "dev.hamasen.action.refresh"
        case unmountServer = "dev.hamasen.action.unmountServer"
    }

    /// Long enough to read, short enough not to feel like a dialog.
    private static let confirmationDuration: TimeInterval = 1.2

    private let messageLabel = NSTextField(labelWithString: "")

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 88))

        messageLabel.alignment = .center
        messageLabel.lineBreakMode = .byTruncatingMiddle
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(messageLabel)

        NSLayoutConstraint.activate([
            messageLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            messageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 20),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
        ])
        view = container
    }

    override func prepare(
        forAction actionIdentifier: String,
        itemIdentifiers: [NSFileProviderItemIdentifier]
    ) {
        guard let action = Action(rawValue: actionIdentifier) else {
            finish(withError: ActionError.unknownAction(actionIdentifier))
            return
        }

        Task {
            do {
                let message = try await perform(action, on: itemIdentifiers)
                await confirm(message)
            } catch {
                await MainActor.run { finish(withError: error) }
            }
        }
    }

    // MARK: - Actions

    private func perform(
        _ action: Action,
        on itemIdentifiers: [NSFileProviderItemIdentifier]
    ) async throws -> String {
        guard let identifier = itemIdentifiers.first else {
            throw ActionError.noSelection
        }
        guard let entity = ItemIdentifierMapper.entity(for: identifier),
              let serverID = entity.serverID
        else {
            throw ActionError.notAHamasenItem
        }

        switch action {
        case .copyRemotePath:
            return try copyRemotePath(of: entity, on: serverID)
        case .refresh:
            return try await refresh()
        case .unmountServer:
            return try await unmountServer(serverID)
        }
    }

    /// Puts the address the item has *on the server* on the clipboard, which
    /// is what you need to reach it over ssh or in another client.
    private func copyRemotePath(of entity: ProviderEntity, on serverID: UUID) throws -> String {
        let config = try Self.config(for: serverID)
        let remotePath = RemotePath.resolve(entity.path, against: config.remotePath)
        let address = "\(config.username)@\(config.host):\(remotePath)"

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
        return "已複製：\(address)"
    }

    /// Remote changes are not pushed, so this asks the system to re-enumerate.
    private func refresh() async throws -> String {
        try await FinderDomain.signalServerListChanged()
        return "已要求重新整理"
    }

    /// Removes the server from the mounted set, then brings the Finder
    /// location in line with what is left. The app and the extension share
    /// that list through the App Group.
    private func unmountServer(_ serverID: UUID) async throws -> String {
        let config = try Self.config(for: serverID)
        let store = try MountedServersStore()
        var mounted = try store.loadMountedServerIDs()
        guard mounted.remove(serverID) != nil else {
            return "「\(config.name)」目前未掛載"
        }
        try store.saveMountedServerIDs(mounted)
        try await FinderDomain.synchronize(hasMountedServers: !mounted.isEmpty)
        return "已卸載「\(config.name)」"
    }

    private static func config(for serverID: UUID) throws -> ServerConfig {
        guard let config = try ServerConfigStore().server(withID: serverID) else {
            throw ActionError.serverMissing
        }
        return config
    }

    // MARK: - Completion

    @MainActor
    private func confirm(_ message: String) async {
        messageLabel.stringValue = message
        messageLabel.textColor = .labelColor
        try? await Task.sleep(for: .seconds(Self.confirmationDuration))
        extensionContext.completeRequest()
    }

    @MainActor
    private func finish(withError error: Error) {
        messageLabel.stringValue = error.localizedDescription
        messageLabel.textColor = .systemRed
        extensionContext.cancelRequest(withError: error)
    }
}

private enum ActionError: LocalizedError {
    case unknownAction(String)
    case noSelection
    case notAHamasenItem
    case serverMissing

    var errorDescription: String? {
        switch self {
        case .unknownAction(let identifier):
            return "不支援的動作：\(identifier)"
        case .noSelection:
            return "沒有選取任何項目"
        case .notAHamasenItem:
            return "這個項目不屬於 Hamasen 掛載"
        case .serverMissing:
            return "找不到對應的伺服器設定"
        }
    }
}
