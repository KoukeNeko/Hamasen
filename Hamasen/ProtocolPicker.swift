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

/// Protocol selector for a server form, shared by the add sheet and the
/// detail pane so both offer the same choices and port behaviour.
struct ProtocolPicker: View {
    @Binding var transferProtocol: ServerConfig.TransferProtocol
    /// Bound to the form's port field so switching protocol can move a port
    /// the user never edited.
    @Binding var portText: String

    var body: some View {
        Picker("協定", selection: $transferProtocol) {
            ForEach(ServerConfig.TransferProtocol.allCases, id: \.self) { transferProtocol in
                Text(transferProtocol.displayName).tag(transferProtocol)
            }
        }
        .onChange(of: transferProtocol) { previous, updated in
            // A port the user typed themselves is left alone; only the
            // previous protocol's default follows the switch.
            if portText == String(previous.defaultPort) {
                portText = String(updated.defaultPort)
            }
        }

        if transferProtocol.isUnencrypted {
            // Said where the choice is made rather than buried in a footer:
            // the alternative is one menu item away, and someone picking
            // this one should know what it costs.
            Label(
                "這個協定不加密，密碼與檔案內容在網路上是可讀的。同一台伺服器若支援，請改用 SFTP 或 FTPS。",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            .labelStyle(.titleAndIcon)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
