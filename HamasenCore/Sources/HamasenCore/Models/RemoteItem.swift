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
    /// An identity the server gives this exact content — an S3 or WebDAV
    /// ETag — when it has one. nil for protocols that only report size and
    /// modification time.
    public let contentTag: String?
    /// A symbolic link reported as what it points at. Its kind is the
    /// target's, so anything that walks a tree checks this before going
    /// inside: a link to an ancestor never ends.
    public let isResolvedLink: Bool

    public var id: String { path }
    public var isDirectory: Bool { kind == .directory }

    public init(
        path: String,
        name: String,
        kind: Kind,
        size: Int64,
        modificationDate: Date? = nil,
        creationDate: Date? = nil,
        permissions: UInt16? = nil,
        contentTag: String? = nil,
        isResolvedLink: Bool = false
    ) {
        self.path = path
        self.name = name
        self.kind = kind
        self.size = size
        self.modificationDate = modificationDate
        self.creationDate = creationDate
        self.permissions = permissions
        self.contentTag = contentTag
        self.isResolvedLink = isResolvedLink
    }

    /// What identifies this item's content, for deciding whether it changed.
    ///
    /// The one derivation both the File Provider item version and the change
    /// watcher's record use: when they disagree, one side sees a change the
    /// other does not. The modification time is cut to whole seconds because
    /// servers report it at different precisions from different calls — an
    /// S3 listing in milliseconds, the HEAD of the same object in seconds —
    /// and a version that differs between a listing and a lookup makes the
    /// system re-download a file that never changed.
    public var contentVersionToken: String {
        if let contentTag {
            return "t\(size)-\(contentTag)"
        }
        let seconds = modificationDate.map { Int64($0.timeIntervalSince1970.rounded(.down)) } ?? 0
        return "\(size)-\(seconds)"
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

    /// Resolves a mount-relative path against the server's base directory.
    /// Shared by every protocol so they agree on what the mount root means.
    public static func resolve(_ mountRelativePath: String, against base: String) -> String {
        if base == root { return mountRelativePath }
        if mountRelativePath == root { return base }
        return base + mountRelativePath
    }

    private static let temporaryUploadPrefix = ".hamasen-upload-"

    /// Where an upload is written before it replaces `path`, beside it so the
    /// final rename stays on the same file system.
    ///
    /// Writing in place truncates the file first: a connection lost halfway
    /// leaves the server holding half a file under the real name.
    public static func temporaryUploadPath(for path: String) -> String {
        let token = UUID().uuidString.prefix(temporaryUploadTokenLength).lowercased()
        return join(parent(of: path), "\(temporaryUploadPrefix)\(token)-\(name(of: path))")
    }

    private static let temporaryUploadTokenLength = 8

    /// Whether a name is an upload still in flight, which listings leave out
    /// so Finder never shows it.
    ///
    /// Only the exact shape `temporaryUploadPath` makes — the prefix, eight
    /// lowercase hex digits, a hyphen, a name — so a file of the user's that
    /// merely starts like one is still listed. Known by its shape rather than
    /// by a record of what this process wrote, because an upload from
    /// another process or another Mac, or one cut short by a crash, has to
    /// stay out of sight too.
    public static func isTemporaryUpload(name: String) -> Bool {
        guard name.hasPrefix(temporaryUploadPrefix) else { return false }
        let rest = name.dropFirst(temporaryUploadPrefix.count)
        let token = rest.prefix(temporaryUploadTokenLength)
        let afterToken = rest.dropFirst(temporaryUploadTokenLength)
        return token.count == temporaryUploadTokenLength
            && token.allSatisfy { $0.isHexDigit && !$0.isUppercase }
            && afterToken.first == "-"
            && afterToken.count > 1
    }

    /// Drops a trailing separator so paths compare equal regardless of how a
    /// server spells a directory.
    public static func withoutTrailingSeparator(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix(separator) else { return path }
        return String(path.dropLast())
    }
}
