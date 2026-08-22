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

/// Imports an OpenSSH private key file through the standard open panel,
/// which is also what grants a sandboxed app access to the chosen file.
enum PrivateKeyImporter {
    struct ImportedKey {
        let text: String
        let fileName: String
        let info: OpenSSHPrivateKey
    }

    enum ImportError: Error, LocalizedError {
        case unreadableFile(underlying: String)

        var errorDescription: String? {
            switch self {
            case .unreadableFile(let underlying):
                return String(localized: "無法讀取金鑰檔案：\(underlying)")
            }
        }
    }

    /// Shows the open panel and returns the chosen key, or nil if cancelled.
    /// Throws when the file cannot be read or is not a usable key.
    @MainActor
    static func promptForKey() throws -> ImportedKey? {
        let panel = NSOpenPanel()
        panel.message = String(localized: "選擇 OpenSSH 私密金鑰檔案")
        panel.prompt = String(localized: "選擇")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // Keys normally live in ~/.ssh, which is hidden by default.
        panel.showsHiddenFiles = true
        let sshDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)
        if FileManager.default.fileExists(atPath: sshDirectory.path) {
            panel.directoryURL = sshDirectory
        }

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ImportError.unreadableFile(underlying: error.localizedDescription)
        }

        // Parse eagerly so an unusable key is rejected at import time rather
        // than at the first connection attempt.
        let info = try OpenSSHPrivateKey.parse(text)
        return ImportedKey(text: text, fileName: url.lastPathComponent, info: info)
    }
}
