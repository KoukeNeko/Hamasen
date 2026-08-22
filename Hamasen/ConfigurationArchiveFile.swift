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

    /// Writes a backup that carries the secrets too, sealed with the
    /// passphrase.
    @MainActor
    static func promptToExport(
        _ archive: ProtectedConfigurationArchive,
        passphrase: String
    ) throws -> Bool {
        let panel = NSSavePanel()
        panel.message = String(localized: "儲存含密碼的 Hamasen 備份")
        panel.prompt = String(localized: "儲存")
        panel.nameFieldStringValue = defaultFileName()
        panel.allowedContentTypes = [UTType(filenameExtension: fileExtension)].compactMap { $0 }

        guard panel.runModal() == .OK, let url = panel.url else { return false }
        try archive.sealed(passphrase: passphrase).write(to: url, options: .atomic)
        return true
    }

    /// What a chosen file turned out to be. The two kinds share an extension
    /// because which one a backup is, is a property of the file rather than
    /// something the user should have to remember when picking it.
    enum Chosen {
        case plain(ConfigurationArchive)
        case protected(Data)
    }

    @MainActor
    static func promptToChooseImport() throws -> Chosen? {
        guard let data = try readChosenFile() else { return nil }
        if ProtectedConfigurationArchive.isProtected(data) {
            return .protected(data)
        }
        return .plain(try ConfigurationArchive.decoded(from: data))
    }

    @MainActor
    private static func readChosenFile() throws -> Data? {
        let panel = NSOpenPanel()
        panel.message = String(localized: "選擇 Hamasen 設定備份")
        panel.prompt = String(localized: "匯入")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: fileExtension), .json].compactMap { $0 }

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return try Data(contentsOf: url)
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
