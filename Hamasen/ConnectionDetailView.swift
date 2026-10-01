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

/// One connection: what it is doing, every setting it has, and the actions
/// that act on it.
///
/// Edits are held until saved, because most of them change where the mount
/// points or how it signs in, and a half-typed host must not reach the
/// extension while the person is still typing it.
struct ConnectionDetailView: View {
    private enum TestState: Equatable {
        case idle
        case testing
        case succeeded
        case failed(String)
    }

    let server: ServerConfig
    let model: ServerListModel
    let onDeleted: () -> Void

    @State private var draft: ConnectionDraft
    @State private var testState: TestState = .idle
    @State private var isSaving = false
    @State private var isConfirmingDelete = false

    /// Cached so the form does not reach into the Keychain on every
    /// keystroke: the body is re-evaluated on each edit, and each lookup is
    /// a synchronous call into securityd.
    @State private var hasStoredPassword = false
    @State private var hasStoredKey = false
    @State private var hasStoredToken = false

    init(server: ServerConfig, model: ServerListModel, onDeleted: @escaping () -> Void) {
        self.server = server
        self.model = model
        self.onDeleted = onDeleted
        _draft = State(initialValue: ConnectionDraft(server: server))
    }

    private var status: ConnectionStatus { model.status(for: server) }

    private var hasUnsavedChanges: Bool {
        guard let config = draft.makeConfig() else { return true }
        return !Self.isEquivalent(config, server) || draft.hasNewSecrets
    }

    private var canSave: Bool {
        draft.makeConfig() != nil
            && draft.hasUsableCredential(
                hasStoredPassword: hasStoredPassword, hasStoredKey: hasStoredKey, hasStoredToken: hasStoredToken)
            && !isSaving
    }

    var body: some View {
        Form {
            Section {
                TextField("名稱", text: $draft.name, prompt: Text(draft.suggestedName))
            } header: {
                header
            }
            ConnectionSettingsSections(
                draft: $draft, model: model,
                hasStoredPassword: hasStoredPassword, hasStoredKey: hasStoredKey, hasStoredToken: hasStoredToken)
            SyncSection(draft: $draft)
            LocalCopySection(draft: $draft, usage: model.cache.usage[server.id] ?? CacheUsage(pinnedBytes: 0, evictableBytes: 0))
            AdvancedConnectionSection(draft: $draft, server: server)
            Section {
                Button("刪除這組連線…", role: .destructive) { isConfirmingDelete = true }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(server.name)
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .task(id: server.id) { refreshStoredCredentials() }
        .refreshingCacheUsage(from: model, restartingOn: server.id)
        .onChange(of: server.isPaused) { _, isPaused in draft.isPaused = isPaused }
        // A result describes the settings it tested, not ones edited since.
        .onChange(of: draft.makeConfig()) { if testState != .testing { testState = .idle } }
        .confirmationDialog(
            "刪除「\(server.name)」？",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("刪除", role: .destructive) {
                Task {
                    await model.removeServer(server)
                    onDeleted()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("連線會從 Finder 移除，儲存的登入資訊也會刪除。伺服器上的檔案不受影響。")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            ServiceIcon(kind: server.serviceKind, size: 52)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(server.name)
                        .font(.title2.bold())
                        .foregroundStyle(.primary)
                    ConnectionStatusBadge(status: status)
                }
                // One line whatever the state, so every connection's header
                // has the same shape; the badge carries the detail on hover.
                Text(verbatim: "\(server.transferProtocol.displayName) · \(server.addressSummary)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if status == .notMounted {
                Button("掛載") { Task { await model.mount(server) } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .textCase(nil)
        .padding(.bottom, 12)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task { await model.revealInFinder(server) }
            } label: {
                Label("在 Finder 中顯示", systemImage: "folder")
            }
            .help("在 Finder 中顯示")
            .disabled(!model.isMounted(server))

            Button {
                Task { await model.setPaused(!server.isPaused, for: server) }
            } label: {
                if server.isPaused {
                    Label("繼續同步", systemImage: "play.fill")
                } else {
                    Label("暫停同步", systemImage: "pause.fill")
                }
            }
            .help(server.isPaused ? "繼續同步" : "暫停同步")
            .disabled(!model.isMounted(server))

            Menu {
                Button("測試連線") { runConnectionTest() }
                    .disabled(draft.makeConfig() == nil || testState == .testing)
                Divider()
                if model.isMounted(server) {
                    Button("從 Finder 卸載") { Task { await model.unmount(server) } }
                } else {
                    Button("掛載到 Finder") { Task { await model.mount(server) } }
                }
                Divider()
                Button("刪除…", role: .destructive) { isConfirmingDelete = true }
            } label: {
                Label("更多", systemImage: "ellipsis.circle")
            }
            .help("更多")
        }
    }

    // MARK: - Bottom bar

    @ViewBuilder
    private var bottomBar: some View {
        if hasUnsavedChanges || testState != .idle {
            HStack(spacing: 12) {
                testResult
                Spacer()
                if hasUnsavedChanges {
                    Button("復原") { revert() }
                        .disabled(isSaving)
                    Button("儲存") { save() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!canSave)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }

    @ViewBuilder
    private var testResult: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView().controlSize(.small)
            Text("連線中…").foregroundStyle(.secondary)
        case .succeeded:
            Label("連線成功", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .lineLimit(2)
                .help(message)
                .textSelection(.enabled)
        }
    }

    // MARK: - Actions

    private func save() {
        guard let config = draft.makeConfig() else { return }
        isSaving = true
        let credentials = draft.credentials
        let intervalChanged = config.effectiveRemoteChangeIntervalSeconds != server.effectiveRemoteChangeIntervalSeconds
        Task {
            defer { isSaving = false }
            // Clearing the fields before knowing the secret was stored would
            // leave no way to retry a failed save.
            if await model.saveServer(config, credentials: credentials) {
                draft.password = ""
                draft.keyPassphrase = ""
                draft.importedKey = nil
                draft.oauthToken = nil
                testState = .idle
                if intervalChanged { model.remoteChanges.checkSoon(config.id) }
            }
            refreshStoredCredentials()
        }
    }

    private func revert() {
        draft = ConnectionDraft(server: server)
        testState = .idle
    }

    private func runConnectionTest() {
        guard let config = draft.makeConfig() else { return }
        testState = .testing
        let credentials = draft.credentials
        let testsSavedSettings = !hasUnsavedChanges
        Task {
            let failure = await model.testConnection(config: config, credentials: credentials)
            if testsSavedSettings, failure == nil {
                // The saved settings working is what the status badge says;
                // a bar repeating it would stay up with nothing to act on.
                model.observe(ServerHealth(state: .reachable), for: server.id)
                testState = .idle
            } else {
                testState = failure.map { .failed($0) } ?? .succeeded
            }
        }
    }

    private func refreshStoredCredentials() {
        hasStoredPassword = model.hasStoredPassword(for: server.id)
        hasStoredKey = model.hasStoredPrivateKey(for: server.id)
        hasStoredToken = model.hasStoredToken(for: server.id)
    }

    /// Equal as far as anyone could tell: a region written as "" and one
    /// never written are the same setting.
    private static func isEquivalent(_ lhs: ServerConfig, _ rhs: ServerConfig) -> Bool {
        var lhs = lhs
        var rhs = rhs
        if lhs.s3Region?.isEmpty ?? true { lhs.s3Region = nil }
        if rhs.s3Region?.isEmpty ?? true { rhs.s3Region = nil }
        return lhs == rhs
    }
}
