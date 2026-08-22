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

/// Shows the SSH host key recorded for a server, and offers the one way back
/// when it stops matching.
///
/// Trust on first use is only safe if the user can act on a mismatch. A
/// server that was genuinely rebuilt presents a new key and is refused from
/// then on, so forgetting the recorded one has to be reachable — with enough
/// said around it that nobody clicks through a real interception.
struct HostKeySection: View {
    let server: ServerConfig

    @State private var fingerprint: String?
    @State private var errorMessage: String?
    @State private var isConfirmingForget = false

    var body: some View {
        Section("主機金鑰") {
            if let fingerprint {
                LabeledContent("指紋") {
                    Text(fingerprint)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Button("清除已記錄的金鑰…", role: .destructive) {
                    isConfirmingForget = true
                }
            } else {
                Text("尚未記錄。第一次連線時會記下伺服器的金鑰，之後每次都會比對。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .task(id: server.hostKeyEndpoint) { load() }
        .confirmationDialog(
            "清除 \(server.hostKeyEndpoint) 已記錄的主機金鑰？",
            isPresented: $isConfirmingForget,
            titleVisibility: .visible
        ) {
            Button("清除", role: .destructive) { forget() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("下次連線會把伺服器出示的任何金鑰當作正確的記下來。只有在你確定伺服器重建過、並且核對過它端的指紋時才這麼做。")
        }
    }

    private func load() {
        do {
            fingerprint = try KnownHostsStore().load().fingerprint(forEndpoint: server.hostKeyEndpoint)
            errorMessage = nil
        } catch {
            fingerprint = nil
            errorMessage = String(localized: "無法讀取已記錄的主機金鑰：\(error.localizedDescription)")
        }
    }

    private func forget() {
        do {
            try KnownHostsStore().forget(endpoint: server.hostKeyEndpoint)
            load()
        } catch {
            errorMessage = String(localized: "無法清除已記錄的主機金鑰：\(error.localizedDescription)")
        }
    }
}
