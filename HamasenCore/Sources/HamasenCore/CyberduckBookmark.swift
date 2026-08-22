import Foundation

/// One file the user chose to import, carried with its name so a bookmark
/// without a nickname can still be named after the file it came from.
public struct CyberduckBookmarkFile: Equatable, Sendable {
    public let name: String
    public let contents: Data

    public init(name: String, contents: Data) {
        self.name = name
        self.contents = contents
    }
}

/// Reads Cyberduck and Mountain Duck bookmarks (`.duck`) and connection
/// profiles (`.cyberduckprofile`) into servers this app can mount.
///
/// Both are property lists over one vocabulary — a profile states as a
/// default what a bookmark states outright — so a single reader covers both
/// and looks a missing key up under the other file's name for it.
///
/// Credentials are deliberately not read: Cyberduck keeps them in the
/// Keychain under its own access group, which this app cannot reach, so an
/// imported server always needs its password or key entered again.
public enum CyberduckBookmark {
    /// A server read out of one file.
    public struct Imported: Equatable, Sendable {
        public let config: ServerConfig
        /// The path the file named, when it could not serve as a mount root.
        /// Cyberduck resolves a relative path against the login directory,
        /// which this app cannot do, so the mount falls back to the root and
        /// the path is reported rather than quietly changed.
        public let unresolvedRemotePath: String?

        public init(config: ServerConfig, unresolvedRemotePath: String? = nil) {
            self.config = config
            self.unresolvedRemotePath = unresolvedRemotePath
        }
    }

    /// What one pass over the chosen files produced.
    ///
    /// Everything that did not become a server is counted rather than
    /// dropped: an import that silently ignores half of a folder looks like
    /// one that worked.
    public struct ImportSummary: Equatable, Sendable {
        public let servers: [Imported]
        /// Protocol identifiers this app cannot mount, in the order the
        /// files named them and without repeats, so they can be shown.
        public let unsupportedProtocols: [String]
        /// Files that named a server already in the list — the same
        /// connection under another nickname.
        public let duplicateCount: Int
        /// Files that were not a property list, or named no host.
        public let unusableCount: Int

        public var isEmpty: Bool {
            servers.isEmpty && unsupportedProtocols.isEmpty
                && duplicateCount == 0 && unusableCount == 0
        }
    }

    /// Reads every file, keeping what this app can mount.
    ///
    /// - Parameters:
    ///   - files: the chosen files, in the order they should be imported.
    ///   - existing: the configured servers, so re-importing a folder does
    ///     not add a second copy of anything already there.
    public static func read(
        _ files: [CyberduckBookmarkFile],
        skippingDuplicatesOf existing: [ServerConfig] = []
    ) -> ImportSummary {
        var servers: [Imported] = []
        var unsupportedProtocols: [String] = []
        var duplicateCount = 0
        var unusableCount = 0
        var seen = Set(existing.map(\.connectionIdentity))

        for file in files {
            switch read(file) {
            case .imported(let imported):
                let key = imported.config.connectionIdentity
                if seen.contains(key) {
                    duplicateCount += 1
                } else {
                    seen.insert(key)
                    servers.append(imported)
                }
            case .unsupported(let identifier):
                if !unsupportedProtocols.contains(identifier) {
                    unsupportedProtocols.append(identifier)
                }
            case .unusable:
                unusableCount += 1
            }
        }

        return ImportSummary(
            servers: servers,
            unsupportedProtocols: unsupportedProtocols,
            duplicateCount: duplicateCount,
            unusableCount: unusableCount
        )
    }

    // MARK: - One file

    private enum Outcome {
        case imported(Imported)
        case unsupported(String)
        case unusable
    }

    private static func read(_ file: CyberduckBookmarkFile) -> Outcome {
        guard let entries = propertyList(from: file.contents) else { return .unusable }
        guard let identifier = string(entries[Key.transferProtocol]) else { return .unusable }
        guard let transferProtocol = transferProtocol(for: identifier) else {
            return .unsupported(identifier)
        }
        guard let host = string(entries[Key.hostname]) ?? string(entries[Key.defaultHostname]) else {
            return .unusable
        }

        let username = string(entries[Key.username]) ?? ""
        let mountRoot = mountRoot(
            from: string(entries[Key.path]) ?? string(entries[Key.defaultPath])
        )
        let config = ServerConfig(
            name: name(from: entries, fileName: file.name, username: username, host: host),
            transferProtocol: transferProtocol,
            host: host,
            port: port(from: entries, defaultingTo: transferProtocol.defaultPort),
            username: username,
            authenticationMethod: entries[Key.privateKeyFile] == nil ? .password : .privateKey,
            remotePath: mountRoot.path
        )
        return .imported(Imported(config: config, unresolvedRemotePath: mountRoot.unresolved))
    }

    // MARK: - Fields

    /// The protocols Hamasen can mount. Anything else — S3, the OAuth
    /// drives — is named back to the user rather than imported as something
    /// it is not.
    private static func transferProtocol(
        for identifier: String
    ) -> ServerConfig.TransferProtocol? {
        switch identifier {
        case "sftp": return .sftp
        case "dav": return .webdav
        case "davs": return .webdavs
        case "ftp": return .ftp
        case "ftps": return .ftps
        default: return nil
        }
    }

    /// A bookmark writes the port as a string and a profile as a number, so
    /// both are accepted. One outside the valid range is discarded the same
    /// way a missing one is: the protocol's own default is always usable.
    private static func port(
        from entries: [String: Any],
        defaultingTo fallback: Int
    ) -> Int {
        let value = entries[Key.port] ?? entries[Key.defaultPort]
        let parsed = (value as? NSNumber)?.intValue ?? string(value).flatMap(Int.init)
        guard let parsed, ServerConfig.validPortRange.contains(parsed) else { return fallback }
        return parsed
    }

    /// Cyberduck's own nickname first, then a profile's description, then
    /// the file name — which is what Cyberduck names its bookmark files
    /// after — and only then something assembled from the connection.
    private static func name(
        from entries: [String: Any],
        fileName: String,
        username: String,
        host: String
    ) -> String {
        if let nickname = string(entries[Key.nickname]) { return nickname }
        if let description = string(entries[Key.description]) { return description }
        let withoutExtension = (fileName as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespaces)
        if !withoutExtension.isEmpty { return withoutExtension }
        return username.isEmpty ? host : "\(username)@\(host)"
    }

    /// The mount root, and the path that had to be given up to reach it.
    ///
    /// Only an absolute path can be a mount root here. Cyberduck resolves
    /// anything else against the login directory, which this app does not
    /// know at import time.
    private static func mountRoot(from path: String?) -> (path: String, unresolved: String?) {
        guard let path, !path.isEmpty else { return (RemotePath.root, nil) }
        guard path.hasPrefix(RemotePath.separator) else { return (RemotePath.root, path) }
        return (ServerConfig.normalizedRemotePath(path), nil)
    }

    // MARK: - Property list

    private static func propertyList(from data: Data) -> [String: Any]? {
        let parsed = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        return parsed as? [String: Any]
    }

    /// Non-empty strings only: Cyberduck writes an empty string for a field
    /// the user left blank, which should fall through to the next candidate
    /// rather than win as a value.
    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The plist keys, as Cyberduck writes them. The `default*` ones belong
    /// to a connection profile, the rest to a bookmark.
    private enum Key {
        static let transferProtocol = "Protocol"
        static let nickname = "Nickname"
        static let description = "Description"
        static let hostname = "Hostname"
        static let defaultHostname = "Default Hostname"
        static let port = "Port"
        static let defaultPort = "Default Port"
        static let username = "Username"
        static let path = "Path"
        static let defaultPath = "Default Path"
        static let privateKeyFile = "Private Key File"
    }
}
