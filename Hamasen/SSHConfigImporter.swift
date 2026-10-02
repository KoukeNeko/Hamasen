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

import AppKit
import HamasenCore

/// Reads the hosts out of an OpenSSH client configuration the user picks.
/// The sandbox gives no standing access to ~/.ssh, so the file has to be
/// chosen in the open panel, which grants it.
enum SSHConfigImporter {
    enum ImportError: Error, LocalizedError {
        case unreadableFile(underlying: String)
        case noHosts

        var errorDescription: String? {
            switch self {
            case .unreadableFile(let underlying):
                return String(localized: "無法讀取 SSH 設定檔：\(underlying)")
            case .noHosts:
                return String(localized: "SSH 設定檔裡沒有具名的主機")
            }
        }
    }

    /// The hosts in the chosen file, or nil if the panel was cancelled.
    @MainActor
    static func promptForHosts() throws -> [SSHConfigHost]? {
        let panel = NSOpenPanel()
        panel.message = String(localized: "選擇 SSH 設定檔")
        panel.prompt = String(localized: "匯入")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = PrivateKeyImporter.sshDirectory.appendingPathComponent("config")

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ImportError.unreadableFile(underlying: error.localizedDescription)
        }
        let hosts = SSHConfig.hosts(in: text)
        guard !hosts.isEmpty else { throw ImportError.noHosts }
        return hosts
    }
}
