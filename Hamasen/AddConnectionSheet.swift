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

/// Adds a connection in two steps: what kind of storage it is, then where
/// it is and how to sign in. Nothing is saved until a connection has been
/// made with what was entered.
struct AddConnectionSheet: View {
    let model: ServerListModel
    /// Told the new connection's identifier once it is added.
    let onAdded: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ConnectionDraft?

    var body: some View {
        Group {
            if let draft = Binding($draft) {
                AddConnectionForm(
                    draft: draft, model: model, onBack: { self.draft = nil }, onCancel: { dismiss() }
                ) { id in
                    onAdded(id)
                    dismiss()
                }
            } else {
                ServiceKindPicker { kind in draft = ConnectionDraft(kind: kind) } onCancel: { dismiss() }
            }
        }
        .frame(width: 580)
    }
}

/// The first step: every kind of storage, grouped the way people think of
/// them.
private struct ServiceKindPicker: View {
    let onChoose: (ServiceKind) -> Void
    let onCancel: () -> Void

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("新增連線")
                    .font(.title2.bold())
                Text("選擇儲存空間的類型")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .top], 24)
            .padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(ServiceKind.Category.allCases) { category in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(category.title)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(category.kinds) { kind in
                                    ServiceKindTile(kind: kind) { onChoose(kind) }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
            .frame(height: 430)

            Divider()
            HStack {
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
    }
}

private struct ServiceKindTile: View {
    let kind: ServiceKind
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ServiceIcon(kind: kind, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(kind.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .contentShape(.rect(cornerRadius: 10))
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isHovering ? AnyShapeStyle(.selection.opacity(0.25)) : AnyShapeStyle(.background.secondary))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.separator)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityHint(Text(kind.summary))
    }
}

/// The second step: the fields for the chosen kind, and the button that
/// tries them before anything is saved.
private struct AddConnectionForm: View {
    @Binding var draft: ConnectionDraft
    let model: ServerListModel
    let onBack: () -> Void
    let onCancel: () -> Void
    let onAdded: (UUID) -> Void

    @State private var isConnecting = false
    @State private var failure: String?

    private var config: ServerConfig? { draft.makeConfig() }

    private var canAdd: Bool {
        config != nil
            && draft.hasUsableCredential(hasStoredPassword: false, hasStoredKey: false, hasStoredToken: false)
            && !isConnecting
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ServiceIcon(kind: draft.kind, size: 32)
                Text(draft.kind.title)
                    .font(.title2.bold())
                Spacer()
            }
            .padding([.horizontal, .top], 24)
            .padding(.bottom, 8)

            Form {
                Section {
                    TextField("名稱", text: $draft.name, prompt: Text(draft.suggestedName))
                }
                ConnectionSettingsSections(draft: $draft, model: model)
                AdvancedConnectionSection(draft: $draft)
            }
            .formStyle(.grouped)
            .frame(height: draft.kind.category == .cloudDrives ? 330 : 430)
            .disabled(isConnecting)

            if let failure {
                Label(failure, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
                    .textSelection(.enabled)
            }

            Divider()
            HStack {
                Button("返回", action: onBack)
                    .disabled(isConnecting)
                Spacer()
                if isConnecting {
                    ProgressView().controlSize(.small)
                    Text("連線中…").foregroundStyle(.secondary)
                }
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("新增") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
            .padding(16)
        }
    }

    private func add() {
        guard let config else { return }
        isConnecting = true
        failure = nil
        let credentials = draft.credentials
        Task {
            defer { isConnecting = false }
            if let message = await model.addConnection(config, credentials: credentials) {
                failure = message
            } else {
                onAdded(config.id)
            }
        }
    }
}
