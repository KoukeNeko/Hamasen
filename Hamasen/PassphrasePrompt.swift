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

import SwiftUI

/// Asks for the passphrase that protects a backup.
///
/// Setting one asks twice, because a passphrase typed wrong here is not
/// discovered until the day the backup is needed, and by then there is
/// nothing to compare it against — the file cannot be opened to check.
struct PassphrasePrompt: View {
    enum Purpose {
        case protectNewBackup
        case openBackup

        var title: LocalizedStringKey {
            switch self {
            case .protectNewBackup: return "設定備份密碼"
            case .openBackup: return "輸入備份密碼"
            }
        }

        var explanation: LocalizedStringKey {
            switch self {
            case .protectNewBackup:
                return "這份備份會包含所有伺服器的密碼與金鑰，並以這組密碼加密。忘記這組密碼就無法還原，沒有其他方法可以取回。"
            case .openBackup:
                return "這份備份是加密的，需要匯出時設定的密碼。"
            }
        }
    }

    let purpose: Purpose
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var passphrase = ""
    @State private var confirmation = ""

    private var isConfirmed: Bool {
        guard !passphrase.isEmpty else { return false }
        guard purpose == .protectNewBackup else { return true }
        return passphrase == confirmation
    }

    private var mismatchWarning: Bool {
        purpose == .protectNewBackup && !confirmation.isEmpty && passphrase != confirmation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(purpose.title)
                .font(.headline)
            Text(purpose.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                SecureField("密碼", text: $passphrase)
                if purpose == .protectNewBackup {
                    SecureField("再輸入一次", text: $confirmation)
                }
            }
            .formStyle(.columns)

            if mismatchWarning {
                Text("兩次輸入的密碼不同。")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("繼續") {
                    onConfirm(passphrase)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isConfirmed)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

extension PassphrasePrompt.Purpose: Equatable {}
