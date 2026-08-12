import HamasenCore
import SwiftUI

/// Add / edit form for a server configuration.
struct ServerFormView: View {
    let existingServer: ServerConfig?
    let onSave: (ServerConfig, String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var host: String
    @State private var portText: String
    @State private var username: String
    @State private var password: String = ""
    @State private var remotePath: String

    init(existingServer: ServerConfig?, onSave: @escaping (ServerConfig, String) -> Void) {
        self.existingServer = existingServer
        self.onSave = onSave
        _name = State(initialValue: existingServer?.name ?? "")
        _host = State(initialValue: existingServer?.host ?? "")
        _portText = State(initialValue: String(existingServer?.port ?? ServerConfig.defaultSFTPPort))
        _username = State(initialValue: existingServer?.username ?? "")
        _remotePath = State(initialValue: existingServer?.remotePath ?? ServerConfig.defaultRemotePath)
    }

    private var isEditing: Bool { existingServer != nil }

    private var parsedPort: Int? {
        guard let port = Int(portText), (1...65535).contains(port) else { return nil }
        return port
    }

    private var isFormValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && parsedPort != nil
            && (isEditing || !password.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("伺服器") {
                    TextField("名稱", text: $name, prompt: Text("我的 NAS"))
                    TextField("主機", text: $host, prompt: Text("example.com"))
                    TextField("連接埠", text: $portText)
                }
                Section("登入") {
                    TextField("使用者名稱", text: $username)
                    SecureField("密碼", text: $password, prompt: isEditing ? Text("留空表示不變更") : nil)
                }
                Section("掛載") {
                    TextField("遠端路徑", text: $remotePath, prompt: Text("/"))
                }
            }
            .formStyle(.grouped)

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
        .frame(width: 420, height: 400)
    }

    private func save() {
        guard let port = parsedPort else { return }
        let config = ServerConfig(
            id: existingServer?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            host: host.trimmingCharacters(in: .whitespaces),
            port: port,
            username: username.trimmingCharacters(in: .whitespaces),
            remotePath: remotePath
        )
        onSave(config, password)
        dismiss()
    }
}

#Preview {
    ServerFormView(existingServer: nil) { _, _ in }
}
