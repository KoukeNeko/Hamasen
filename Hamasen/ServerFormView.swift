import HamasenCore
import SwiftUI

/// Sheet for adding a new server.
struct ServerFormView: View {
    let existingServer: ServerConfig?
    let onSave: (ServerConfig, CredentialUpdate) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var host: String
    @State private var portText: String
    @State private var username: String
    @State private var remotePath: String

    @State private var authenticationMethod: ServerConfig.AuthenticationMethod
    @State private var password: String = ""
    @State private var importedKey: PrivateKeyImporter.ImportedKey?
    @State private var keyPassphrase: String = ""

    init(existingServer: ServerConfig?, onSave: @escaping (ServerConfig, CredentialUpdate) -> Void) {
        self.existingServer = existingServer
        self.onSave = onSave
        _name = State(initialValue: existingServer?.name ?? "")
        _host = State(initialValue: existingServer?.host ?? "")
        _portText = State(initialValue: String(existingServer?.port ?? AppSettings.defaultServerPort()))
        _username = State(initialValue: existingServer?.username ?? "")
        _remotePath = State(initialValue: existingServer?.remotePath ?? ServerConfig.defaultRemotePath)
        _authenticationMethod = State(initialValue: existingServer?.authenticationMethod ?? .password)
    }

    private var isEditing: Bool { existingServer != nil }

    private var parsedPort: Int? {
        guard let port = Int(portText), (1...65535).contains(port) else { return nil }
        return port
    }

    private var hasCredential: Bool {
        switch authenticationMethod {
        case .password:
            return isEditing || !password.isEmpty
        case .privateKey:
            return importedKey != nil
        }
    }

    private var isFormValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && parsedPort != nil
            && hasCredential
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("伺服器") {
                    TextField("名稱", text: $name, prompt: Text("我的 NAS"))
                    TextField("主機", text: $host, prompt: Text("example.com"))
                    TextField("連接埠", text: $portText)
                    TextField("使用者名稱", text: $username)
                }
                AuthenticationFields(
                    method: $authenticationMethod,
                    password: $password,
                    importedKey: $importedKey,
                    keyPassphrase: $keyPassphrase,
                    hasStoredKey: false,
                    allowsBlankPassword: isEditing
                )
                Section("掛載") {
                    TextField("遠端路徑", text: $remotePath, prompt: Text("/"))
                }
            }
            .formStyle(.grouped)
            // Lay the form out at its natural height so the sheet grows to
            // fit instead of scrolling; the height changes with the selected
            // authentication method.
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isEditing ? "儲存" : "新增") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isFormValid)
            }
            .padding()
        }
        .frame(width: 440)
    }

    private func save() {
        guard let port = parsedPort else { return }
        let config = ServerConfig(
            id: existingServer?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            host: host.trimmingCharacters(in: .whitespaces),
            port: port,
            username: username.trimmingCharacters(in: .whitespaces),
            authenticationMethod: authenticationMethod,
            remotePath: remotePath
        )
        let credentials = CredentialUpdate(
            password: password,
            privateKey: importedKey?.text,
            keyPassphrase: keyPassphrase
        )
        onSave(config, credentials)
        dismiss()
    }
}

#Preview {
    ServerFormView(existingServer: nil) { _, _ in }
}
