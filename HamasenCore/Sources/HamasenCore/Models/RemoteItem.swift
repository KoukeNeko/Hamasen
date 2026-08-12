import Foundation

/// A single node in the remote file system (file, directory, or symlink).
public struct RemoteItem: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case file
        case directory
        case symlink
    }

    /// Full path relative to the mount root, always starting with "/"
    /// (e.g. "/docs/report.pdf").
    public let path: String
    public let name: String
    public let kind: Kind
    public let size: Int64
    public let modificationDate: Date?
    public let creationDate: Date?
    /// POSIX permissions (e.g. 0o644); nil when unknown.
    public let permissions: UInt16?

    public var id: String { path }
    public var isDirectory: Bool { kind == .directory }

    public init(
        path: String,
        name: String,
        kind: Kind,
        size: Int64,
        modificationDate: Date? = nil,
        creationDate: Date? = nil,
        permissions: UInt16? = nil
    ) {
        self.path = path
        self.name = name
        self.kind = kind
        self.size = size
        self.modificationDate = modificationDate
        self.creationDate = creationDate
        self.permissions = permissions
    }
}

/// Remote path helpers: centralizes "/"-separated path math so string
/// concatenation is not scattered across the codebase.
public enum RemotePath {
    public static let separator = "/"
    public static let root = "/"

    public static func join(_ directory: String, _ name: String) -> String {
        if directory == root { return root + name }
        return directory + separator + name
    }

    public static func parent(of path: String) -> String {
        guard path != root else { return root }
        let components = path.split(separator: Character(separator))
        guard components.count > 1 else { return root }
        return root + components.dropLast().joined(separator: separator)
    }

    public static func name(of path: String) -> String {
        guard path != root else { return root }
        return String(path.split(separator: Character(separator)).last ?? "")
    }
}
