import AppKit
import HamasenCore
import UniformTypeIdentifiers

/// Writes a configuration backup out and reads one back in, through the
/// panels that are also what grant a sandboxed app access to the file.
enum ConfigurationArchiveFile {
    /// A JSON file with a name of its own, so it is recognisable in a folder
    /// of backups and cannot be confused with the app's internal stores.
    private static let fileExtension = "hamasenbackup"

    @MainActor
    static func promptToExport(_ archive: ConfigurationArchive) throws -> Bool {
        let panel = NSSavePanel()
        panel.message = String(localized: "儲存 Hamasen 設定備份")
        panel.prompt = String(localized: "儲存")
        panel.nameFieldStringValue = defaultFileName()
        panel.allowedContentTypes = [UTType(filenameExtension: fileExtension)].compactMap { $0 }

        guard panel.runModal() == .OK, let url = panel.url else { return false }
        try archive.encoded().write(to: url, options: .atomic)
        return true
    }

    @MainActor
    static func promptToImport() throws -> ConfigurationArchive? {
        let panel = NSOpenPanel()
        panel.message = String(localized: "選擇 Hamasen 設定備份")
        panel.prompt = String(localized: "匯入")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: fileExtension), .json].compactMap { $0 }

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return try ConfigurationArchive.decoded(from: try Data(contentsOf: url))
    }

    /// Dated, because the reason to keep more than one is to go back to an
    /// earlier day.
    private static func defaultFileName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "Hamasen \(formatter.string(from: Date())).\(fileExtension)"
    }
}
