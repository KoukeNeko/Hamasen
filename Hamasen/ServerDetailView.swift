import HamasenCore
import SwiftUI

/// Detail pane for one server: status header, editable settings with
/// explicit save, connection test, and deletion.
struct ServerDetailView: View {
    private enum ConnectionTestState: Equatable {
        case idle
        case testing
        case success
        case failure(String)
    }

    let server: ServerConfig
    let isMounted: Bool
    let model: ServerListModel
    let onDeleted: () -> Void

    @State private var draftName: String
    @State private var draftProtocol: ServerConfig.TransferProtocol
    @State private var draftHost: String
    @State private var draftPortText: String
    @State private var draftUsername: String
    @State private var draftPassword: String = ""
    @State private var draftRemotePath: String
    @State private var draftStorageMode: ServerConfig.StorageMode
    @State private var draftCacheAllowance: CacheAllowance
    @State private var draftAuthenticationMethod: ServerConfig.AuthenticationMethod
    @State private var importedKey: PrivateKeyImporter.ImportedKey?
    @State private var draftKeyPassphrase: String = ""

    @State private var testState: ConnectionTestState = .idle
    @State private var isConfirmingDelete = false

    /// Cached so the form does not reach into the Keychain on every keystroke:
    /// the body is re-evaluated on each edit, and each lookup is a synchronous
    /// call into securityd.
    @State private var hasStoredPassword = false
    @State private var hasStoredPrivateKey = false

    init(server: ServerConfig, isMounted: Bool, model: ServerListModel, onDeleted: @escaping () -> Void) {
        self.server = server
        self.isMounted = isMounted
        self.model = model
        self.onDeleted = onDeleted
        _draftName = State(initialValue: server.name)
        _draftProtocol = State(initialValue: server.transferProtocol)
        _draftHost = State(initialValue: server.host)
        _draftPortText = State(initialValue: String(server.port))
        _draftUsername = State(initialValue: server.username)
        _draftRemotePath = State(initialValue: server.remotePath)
        _draftStorageMode = State(initialValue: server.storageMode)
        _draftCacheAllowance = State(initialValue: CacheAllowance(bytes: server.cacheLimitBytes))
        _draftAuthenticationMethod = State(initialValue: server.authenticationMethod)
    }

    // MARK: - Draft state

    private var parsedPort: Int? {
        guard let port = Int(draftPortText), (1...65535).contains(port) else { return nil }
        return port
    }

    private var draftConfig: ServerConfig? {
        guard let port = parsedPort else { return nil }
        let name = draftName.trimmingCharacters(in: .whitespaces)
        let host = draftHost.trimmingCharacters(in: .whitespaces)
        let username = draftUsername.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !host.isEmpty, !username.isEmpty else { return nil }
        return ServerConfig(
            id: server.id,
            name: name,
            transferProtocol: draftProtocol,
            host: host,
            port: port,
            username: username,
            authenticationMethod: draftAuthenticationMethod,
            remotePath: draftRemotePath,
            storageMode: draftStorageMode,
            cacheLimitBytes: draftCacheAllowance.bytes
        )
    }

    private var draftCredentials: CredentialUpdate {
        // Only the secret the chosen method actually uses is written, so a
        // key kept for a possible switch back never lands in the Keychain of
        // a password-authenticated server.
        let usesKey = draftAuthenticationMethod == .privateKey
        return CredentialUpdate(
            password: usesKey ? "" : draftPassword,
            privateKey: usesKey ? importedKey?.text : nil,
            keyPassphrase: usesKey ? draftKeyPassphrase : ""
        )
    }

    /// Each authentication method needs its own secret from somewhere — newly
    /// entered or already stored. Without this check, switching a key-based
    /// server to a protocol that only does passwords would save a server that
    /// can never authenticate.
    private var hasUsableCredential: Bool {
        switch draftAuthenticationMethod {
        case .password:
            return !draftPassword.isEmpty || hasStoredPassword
        case .privateKey:
            return importedKey != nil || hasStoredPrivateKey
        }
    }

    private var hasUnsavedChanges: Bool {
        guard let draftConfig, hasUsableCredential else { return false }
        return draftConfig != server
            || !draftPassword.isEmpty
            || importedKey != nil
            || !draftKeyPassphrase.isEmpty
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            settingsForm
            Divider()
            footer
        }
        .task(id: server.id) {
            refreshStoredCredentials()
        }
        .confirmationDialog(
            "確定要刪除「\(server.name)」嗎？",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("刪除伺服器", role: .destructive) {
                Task {
                    await model.removeServer(server)
                    onDeleted()
                }
            }
        } message: {
            Text("已掛載的內容會從 Finder 移除，儲存的密碼也會一併刪除。")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.system(size: 34))
                .foregroundStyle(isMounted ? Color.green : Color.secondary)
                .frame(width: 48)

            VStack(alignment: .leading, spacing: 4) {
                Text(server.name)
                    .font(.title2.bold())
                HStack(spacing: 6) {
                    badge(server.transferProtocol.displayName, tint: .blue)
                    badge(server.authenticationMethod.displayName, tint: .purple)
                    badge(
                        isMounted ? "已掛載" : "未掛載",
                        tint: isMounted ? .green : .gray
                    )
                    Text("\(server.username)@\(server.host):\(String(server.port))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button {
                Task {
                    if isMounted {
                        await model.unmount(server)
                    } else {
                        await model.mount(server)
                    }
                }
            } label: {
                Label(
                    isMounted ? "卸載" : "掛載",
                    systemImage: isMounted ? "eject.fill" : "externaldrive.badge.checkmark"
                )
                .frame(minWidth: 72)
            }
            .buttonStyle(.borderedProminent)
            .tint(isMounted ? .orange : .accentColor)
            .controlSize(.large)
        }
        .padding(20)
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
    }

    // MARK: - Settings form

    private var settingsForm: some View {
        Form {
            Section("伺服器") {
                TextField("名稱", text: $draftName)
                ProtocolPicker(transferProtocol: $draftProtocol, portText: $draftPortText)
                TextField("主機", text: $draftHost, prompt: Text("example.com"))
                TextField("連接埠", text: $draftPortText)
                TextField("使用者名稱", text: $draftUsername)
            }
            Section("掛載") {
                TextField("遠端路徑", text: $draftRemotePath, prompt: Text("/"))
                Picker("儲存方式", selection: $draftStorageMode) {
                    ForEach(ServerConfig.StorageMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Picker("本機空間上限", selection: $draftCacheAllowance) {
                    ForEach(CacheAllowance.allCases) { allowance in
                        Text(allowance.displayName).tag(allowance)
                    }
                }
                .disabled(draftStorageMode == .onlineOnly)
            }
            AuthenticationFields(
                method: $draftAuthenticationMethod,
                password: $draftPassword,
                importedKey: $importedKey,
                keyPassphrase: $draftKeyPassphrase,
                hasStoredKey: hasStoredPrivateKey,
                // Only offer "leave blank to keep" when there is in fact a
                // stored password to keep.
                allowsBlankPassword: hasStoredPassword,
                allowsPrivateKey: draftProtocol.supportsPrivateKeyAuthentication
            )
        }
        .formStyle(.grouped)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                runConnectionTest()
            } label: {
                Label("測試連線", systemImage: "bolt.horizontal")
            }
            .disabled(draftConfig == nil || testState == .testing)

            switch testState {
            case .idle:
                EmptyView()
            case .testing:
                ProgressView()
                    .controlSize(.small)
            case .success:
                Label("連線成功", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            case .failure(let message):
                Label(message, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .lineLimit(1)
                    .help(message)
            }

            Spacer()

            Button("刪除伺服器…", role: .destructive) {
                isConfirmingDelete = true
            }

            Button("儲存變更") {
                guard let draftConfig else { return }
                Task {
                    // Clearing the fields before knowing the secret was
                    // stored would leave no way to retry a failed save.
                    if await model.saveServer(draftConfig, credentials: draftCredentials) {
                        draftPassword = ""
                        draftKeyPassphrase = ""
                        importedKey = nil
                    }
                    refreshStoredCredentials()
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!hasUnsavedChanges)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func refreshStoredCredentials() {
        hasStoredPassword = model.hasStoredPassword(for: server.id)
        hasStoredPrivateKey = model.hasStoredPrivateKey(for: server.id)
    }

    private func runConnectionTest() {
        guard let draftConfig else { return }
        testState = .testing
        let credentials = draftCredentials
        Task {
            let failureMessage = await model.testConnection(
                config: draftConfig,
                credentials: credentials
            )
            testState = failureMessage.map { .failure($0) } ?? .success
        }
    }
}
