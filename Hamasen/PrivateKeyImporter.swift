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
                return "無法讀取金鑰檔案：\(underlying)"
            }
        }
    }

    /// Shows the open panel and returns the chosen key, or nil if cancelled.
    /// Throws when the file cannot be read or is not a usable key.
    @MainActor
    static func promptForKey() throws -> ImportedKey? {
        let panel = NSOpenPanel()
        panel.message = "選擇 OpenSSH 私密金鑰檔案"
        panel.prompt = "選擇"
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
