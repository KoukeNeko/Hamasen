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

import HamasenCore
import SwiftUI

/// Sheet for adding a new server.
struct ServerFormView: View {
    let existingServer: ServerConfig?
    let onSave: (ServerConfig, CredentialUpdate) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var transferProtocol: ServerConfig.TransferProtocol
    @State private var host: String
    @State private var portText: String
    @State private var username: String
    @State private var remotePath: String
    @State private var storageMode: ServerConfig.StorageMode
    @State private var cacheAllowance: CacheAllowance

    @State private var authenticationMethod: ServerConfig.AuthenticationMethod
    @State private var password: String = ""
    @State private var importedKey: PrivateKeyImporter.ImportedKey?
    @State private var keyPassphrase: String = ""

    init(existingServer: ServerConfig?, onSave: @escaping (ServerConfig, CredentialUpdate) -> Void) {
        self.existingServer = existingServer
        self.onSave = onSave
        _name = State(initialValue: existingServer?.name ?? "")
        _transferProtocol = State(initialValue: existingServer?.transferProtocol ?? .sftp)
        _host = State(initialValue: existingServer?.host ?? "")
        _portText = State(initialValue: String(existingServer?.port ?? AppSettings.defaultServerPort()))
        _username = State(initialValue: existingServer?.username ?? "")
        _remotePath = State(initialValue: existingServer?.remotePath ?? ServerConfig.defaultRemotePath)
        _storageMode = State(initialValue: existingServer?.storageMode ?? .automatic)
        _cacheAllowance = State(initialValue: CacheAllowance(bytes: existingServer?.cacheLimitBytes))
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
                    ProtocolPicker(transferProtocol: $transferProtocol, portText: $portText)
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
                    allowsBlankPassword: isEditing,
                    allowsPrivateKey: transferProtocol.supportsPrivateKeyAuthentication
                )
                Section("掛載") {
                    TextField("遠端路徑", text: $remotePath, prompt: Text("/"))
                    Picker("儲存方式", selection: $storageMode) {
                        ForEach(ServerConfig.StorageMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    Picker("本機空間上限", selection: $cacheAllowance) {
                        ForEach(CacheAllowance.allCases) { allowance in
                            Text(allowance.displayName).tag(allowance)
                        }
                    }
                    .disabled(storageMode == .onlineOnly)
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
            transferProtocol: transferProtocol,
            host: host.trimmingCharacters(in: .whitespaces),
            port: port,
            username: username.trimmingCharacters(in: .whitespaces),
            authenticationMethod: authenticationMethod,
            remotePath: remotePath,
            storageMode: storageMode,
            cacheLimitBytes: cacheAllowance.bytes
        )
        let usesKey = authenticationMethod == .privateKey
        let credentials = CredentialUpdate(
            password: usesKey ? "" : password,
            privateKey: usesKey ? importedKey?.text : nil,
            keyPassphrase: usesKey ? keyPassphrase : ""
        )
        onSave(config, credentials)
        dismiss()
    }
}

#Preview {
    ServerFormView(existingServer: nil) { _, _ in }
}
