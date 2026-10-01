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

/// The fields that say where a connection goes and how it signs in, for the
/// kind being edited. Shared by the add sheet and the detail pane.
struct ConnectionSettingsSections: View {
    @Binding var draft: ConnectionDraft
    let model: ServerListModel
    /// Whether a secret is already stored, so a blank field can mean "keep
    /// it" rather than "none".
    var hasStoredPassword = false
    var hasStoredKey = false
    var hasStoredToken = false

    var body: some View {
        switch draft.kind.category {
        case .cloudDrives:
            CloudAccountSection(draft: $draft, model: model, hasStoredToken: hasStoredToken)
            Section("資料夾") {
                TextField("起始資料夾", text: $draft.remotePath, prompt: Text(verbatim: "/"))
            }
        case .servers, .objectStorage:
            Section("連線設定") {
                serverFields
            }
            if draft.kind == .sftp {
                AuthenticationFields(
                    method: $draft.authenticationMethod,
                    password: $draft.password,
                    importedKey: $draft.importedKey,
                    keyPassphrase: $draft.keyPassphrase,
                    hasStoredKey: hasStoredKey,
                    allowsBlankPassword: hasStoredPassword,
                    allowsPrivateKey: true
                )
            }
        }
    }

    @ViewBuilder
    private var serverFields: some View {
        switch draft.kind {
        case .webdav:
            TextField("網址", text: $draft.address, prompt: Text(verbatim: "https://nas.local:5006"))
                .textContentType(.URL)
            if ServerAddress.parse(draft.address)?.scheme == "http" {
                UnencryptedWarning()
            }
            accountFields
        case .smb:
            TextField("主機", text: $draft.address, prompt: Text("例如 192.168.1.20"))
            accountFields
            SMBSharePicker(draft: $draft, hasStoredPassword: hasStoredPassword, model: model)
            TextField("路徑", text: $draft.remotePath, prompt: Text(verbatim: "/"))
        case .sftp:
            TextField("主機", text: $draft.address, prompt: Text("例如 192.168.1.20"))
            TextField("連接埠", text: $draft.portText)
            TextField("使用者名稱", text: $draft.username)
                .textContentType(.username)
            TextField("起始路徑", text: $draft.remotePath, prompt: Text(verbatim: "/"))
        case .ftp:
            TextField("主機", text: $draft.address, prompt: Text("例如 192.168.1.20"))
            TextField("連接埠", text: $draft.portText)
            Toggle("使用 TLS 加密（FTPS）", isOn: Binding(
                get: { draft.transferProtocol == .ftps },
                set: { draft.transferProtocol = $0 ? .ftps : .ftp }))
            if draft.transferProtocol == .ftp {
                UnencryptedWarning()
            }
            accountFields
            TextField("起始路徑", text: $draft.remotePath, prompt: Text(verbatim: "/"))
        case .s3:
            TextField("端點", text: $draft.address, prompt: Text(verbatim: "<account>.r2.cloudflarestorage.com"))
                .textContentType(.URL)
            TextField("Access Key ID", text: $draft.username)
            SecureField(
                "Secret Access Key", text: $draft.password,
                prompt: hasStoredPassword ? Text("留空表示不變更") : nil)
            TextField("Bucket 與路徑", text: $draft.remotePath, prompt: Text(verbatim: "/my-bucket"))
            S3RemotePathFooter(remotePath: draft.remotePath, transferProtocol: .s3)
        case .googleDrive, .oneDrive, .dropbox:
            EmptyView()
        }
    }

    @ViewBuilder
    private var accountFields: some View {
        TextField("使用者名稱", text: $draft.username)
            .textContentType(.username)
        SecureField("密碼", text: $draft.password, prompt: hasStoredPassword ? Text("留空表示不變更") : nil)
            .textContentType(.password)
    }
}

/// Said where an unencrypted choice is made rather than buried in a
/// footer: the encrypted alternative is one switch away.
private struct UnencryptedWarning: View {
    var body: some View {
        Label("不加密：密碼與檔案內容在網路上可被讀取。", systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .labelStyle(.titleAndIcon)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Who a cloud drive connection is signed in as, and the button that signs
/// in again in the browser.
private struct CloudAccountSection: View {
    @Binding var draft: ConnectionDraft
    let model: ServerListModel
    let hasStoredToken: Bool

    @State private var signIn: Task<Void, Never>?
    @State private var failure: String?
    @Environment(AppNavigation.self) private var navigation

    private var provider: OAuthProvider { draft.transferProtocol.oauthProvider! }
    private var isSignedIn: Bool { draft.oauthToken != nil || hasStoredToken }

    var body: some View {
        Section("帳號") {
            LabeledContent("帳號") {
                HStack(spacing: 8) {
                    if signIn != nil {
                        ProgressView().controlSize(.small)
                        Text("等待瀏覽器登入…").foregroundStyle(.secondary)
                    } else if isSignedIn {
                        Text(draft.username.isEmpty ? String(localized: "已登入") : draft.username)
                            .textSelection(.enabled)
                    } else {
                        Text("未登入").foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                if signIn != nil {
                    Button("取消") { cancel() }
                } else {
                    Button(isSignedIn ? "重新登入…" : "在瀏覽器登入…") { start() }
                        .disabled(OAuthClient.configured(for: provider) == nil)
                }
                Spacer()
            }
            if OAuthClient.configured(for: provider) == nil {
                LabeledContent {
                    Button("前往設定") {
                        navigation.isAddingConnection = false
                        navigation.selection = .settings(.cloud)
                    }
                } label: {
                    Label("尚未設定 \(provider.displayName) 的用戶端 ID", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            if let failure {
                Label(failure, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { cancel() }
    }

    private func start() {
        failure = nil
        let provider = provider
        signIn = Task {
            defer { signIn = nil }
            do {
                let result = try await model.signIn(to: provider)
                draft.oauthToken = result.token
                if !result.email.isEmpty { draft.username = result.email }
            } catch OAuthError.cancelled {
                // Closed or declined in the browser: nothing to report.
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func cancel() {
        signIn?.cancel()
        signIn = nil
    }
}

/// The share an SMB connection opens, picked from what the server offers
/// once it has been asked, or typed.
private struct SMBSharePicker: View {
    @Binding var draft: ConnectionDraft
    let hasStoredPassword: Bool
    let model: ServerListModel

    @State private var shares: [String] = []
    @State private var isLoading = false
    @State private var failure: String?

    var body: some View {
        LabeledContent("共用資料夾") {
            HStack(spacing: 8) {
                if shares.isEmpty {
                    TextField("共用資料夾", text: $draft.share, prompt: Text("例如 Public"))
                        .labelsHidden()
                } else {
                    Picker("共用資料夾", selection: $draft.share) {
                        if !shares.contains(draft.share) {
                            Text(draft.share.isEmpty ? String(localized: "選擇") : draft.share).tag(draft.share)
                        }
                        ForEach(shares, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                }
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button("列出") { load() }
                        .disabled(ServerAddress.parse(draft.address) == nil)
                        .help("列出伺服器上的共用資料夾")
                }
            }
        }
        if let failure {
            Label(failure, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func load() {
        guard let address = ServerAddress.parse(draft.address) else { return }
        let password = draft.password.isEmpty && hasStoredPassword
            ? model.storedPassword(for: draft.id) ?? ""
            : draft.password
        let port = address.port ?? Int(draft.portText) ?? ServerConfig.TransferProtocol.smb.defaultPort
        let username = draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
        isLoading = true
        failure = nil
        Task {
            defer { isLoading = false }
            do {
                shares = try await SMBFileService.shares(
                    host: address.host, port: port, username: username, password: password,
                    connectTimeoutSeconds: AppSettings.connectTimeoutSeconds())
                if draft.share.isEmpty, let first = shares.first { draft.share = first }
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// How often the server is asked what changed, and whether it is indexed
/// for Spotlight.
struct SyncSection: View {
    @Binding var draft: ConnectionDraft

    var body: some View {
        Section("同步") {
            Picker("檢查遠端變更", selection: $draft.remoteChangeInterval) {
                ForEach(RemoteChangeInterval.allCases) { interval in
                    Text(interval.title).tag(interval)
                }
            }
            BackgroundIndexingToggle(isOn: $draft.indexesInBackground, transferProtocol: draft.transferProtocol)
        }
    }
}

/// How much of the connection may stay on this Mac.
struct LocalCopySection: View {
    @Binding var draft: ConnectionDraft
    var usage: CacheUsage?

    var body: some View {
        Section("本機複本") {
            Picker("儲存方式", selection: $draft.storageMode) {
                ForEach(ServerConfig.StorageMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            Picker("本機空間上限", selection: $draft.cacheAllowance) {
                ForEach(CacheAllowance.allCases) { allowance in
                    Text(allowance.displayName).tag(allowance)
                }
            }
            .disabled(draft.storageMode == .onlineOnly)
            if let usage {
                StorageBarView(usage: usage, allowance: draft.cacheAllowance.bytes)
                    .padding(.vertical, 4)
            }
        }
    }
}

/// Settings that override a default which suits nearly everyone.
struct AdvancedConnectionSection: View {
    @Binding var draft: ConnectionDraft
    /// The saved connection, for the parts that act on what is stored.
    var server: ServerConfig?

    @State private var isExpanded = false

    var body: some View {
        if hasAdvancedSettings {
            Section {
                DisclosureGroup("進階", isExpanded: $isExpanded) {
                    if draft.kind == .smb || draft.kind == .s3 {
                        TextField("連接埠", text: $draft.portText)
                    }
                    if draft.kind == .s3 {
                        TextField("區域", text: $draft.s3Region, prompt: Text("自動判斷"))
                        Picker("定址方式", selection: $draft.s3AddressingStyle) {
                            ForEach(S3AddressingStyle.allCases, id: \.self) { style in
                                Text(style.displayName).tag(style)
                            }
                        }
                    }
                }
            }
        }
        if let server, server.transferProtocol.supportsPrivateKeyAuthentication {
            // SSH is the only protocol here with a host key of its own; the
            // rest ride on TLS, which the system validates.
            HostKeySection(server: server)
        }
    }

    private var hasAdvancedSettings: Bool {
        draft.kind == .smb || draft.kind == .s3
    }
}
