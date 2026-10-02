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

public enum S3PathError: Error, Equatable, Sendable {
    /// The server path named no bucket. Reachable only through a
    /// misconfigured server whose remote path is "/", so it is reported
    /// rather than guessed around.
    case noBucketInPath(String)
}

/// The two names S3 addresses an object by, derived from the single path the
/// rest of the app speaks.
///
/// `ServerConfig.remotePath` holds `/bucket/prefix`, and `RemotePath.resolve`
/// turns a mount-relative path into `/bucket/prefix/whatever`. Everything
/// after the first component is the key; S3 has no notion of the segments
/// inside it, which is why a "directory" here is only ever a prefix.
public struct S3ObjectKey: Sendable, Equatable {
    public let bucket: String
    /// Verbatim, except for a leading separator that S3 keys never carry.
    /// A trailing one is kept: `photos/` and `photos` are different objects,
    /// and that difference is the entire existence of an empty folder.
    public let key: String

    public init(bucket: String, key: String) {
        self.bucket = bucket
        self.key = Self.trimmingLeadingSeparators(key)
    }

    /// Splits a server-absolute path, the form `RemotePath.resolve` produces.
    public init(absolutePath: String) throws {
        let trimmed = Self.trimmingSeparators(absolutePath)
        guard let separator = trimmed.firstIndex(of: Character(RemotePath.separator)) else {
            guard !trimmed.isEmpty else { throw S3PathError.noBucketInPath(absolutePath) }
            self.init(bucket: trimmed, key: "")
            return
        }
        self.init(
            bucket: String(trimmed[trimmed.startIndex..<separator]),
            key: String(trimmed[trimmed.index(after: separator)...]))
    }

    /// What `ListObjectsV2` is asked for, and what a folder marker is named.
    ///
    /// The bucket root is the empty string rather than "/", because S3 keys
    /// do not begin with a separator and asking for one lists nothing.
    public var directoryPrefix: String {
        if key.isEmpty { return "" }
        return key.hasSuffix(RemotePath.separator) ? key : key + RemotePath.separator
    }

    /// The zero-byte object that makes an otherwise empty folder visible.
    /// S3 has no directories, so this marker is the whole of their existence.
    public var folderMarkerKey: String { directoryPrefix }

    /// The marker addressed as an object, with its trailing separator intact.
    public var folderMarker: S3ObjectKey {
        S3ObjectKey(bucket: bucket, key: folderMarkerKey)
    }

    public var isBucketRoot: Bool { key.isEmpty }

    /// The inverse of `init(absolutePath:)`, for turning a listing back into
    /// the paths the protocol hands out.
    public var absolutePath: String {
        key.isEmpty
            ? RemotePath.root + bucket
            : RemotePath.root + bucket + RemotePath.separator + key
    }

    public func appending(_ component: String) -> S3ObjectKey {
        S3ObjectKey(bucket: bucket, key: key.isEmpty ? component : key + RemotePath.separator + component)
    }

    private static func trimmingLeadingSeparators(_ value: String) -> String {
        var trimmed = Substring(value)
        while trimmed.hasPrefix(RemotePath.separator) { trimmed = trimmed.dropFirst() }
        return String(trimmed)
    }

    /// Only the ends are trimmed, and only for a path: a trailing separator
    /// there is syntax, not part of a name. A key may legitimately contain
    /// "//" — S3 stores keys as opaque strings — so collapsing interior runs
    /// would rename somebody's object.
    private static func trimmingSeparators(_ value: String) -> String {
        var trimmed = Substring(value)
        while trimmed.hasPrefix(RemotePath.separator) { trimmed = trimmed.dropFirst() }
        while trimmed.hasSuffix(RemotePath.separator) { trimmed = trimmed.dropLast() }
        return String(trimmed)
    }
}
