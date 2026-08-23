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

/// A breadth-first walk over every mounted server, one directory per step.
///
/// The working set is what the system keeps in the replica and what Spotlight
/// indexes. The system asks for it a page at a time and lets the extension
/// name the next page in 500 bytes — room for a cursor, not for the queue a
/// breadth-first walk needs. So the walk itself lives in a file the extension
/// and the app share, and the page token carries only which step of which
/// walk to resume. A token for a walk that no longer exists starts a new one.
///
/// Breadth-first, because what is near the top is what people look for first,
/// and because a depth limit on a breadth-first walk cuts off uniformly
/// rather than spending the whole budget down one branch.
public struct WorkingSetWalk: Equatable, Sendable, Codable {
    /// One directory still to be listed.
    public struct Pending: Equatable, Sendable, Codable {
        public let serverID: UUID
        public let path: String
        public let depth: Int

        public init(serverID: UUID, path: String, depth: Int) {
            self.serverID = serverID
            self.path = path
            self.depth = depth
        }
    }

    /// Limits that keep the walk from becoming the server's whole day.
    ///
    /// Every directory is one listing request. On S3 that is a billed
    /// operation; on SFTP it is load on somebody's machine.
    public struct Limits: Equatable, Sendable, Codable {
        public let maximumDepth: Int
        public let maximumDirectories: Int

        public init(maximumDepth: Int, maximumDirectories: Int) {
            self.maximumDepth = maximumDepth
            self.maximumDirectories = maximumDirectories
        }

        public static let `default` = Limits(maximumDepth: 6, maximumDirectories: 2_000)
    }

    /// Distinguishes this walk from the one before it, so a page token that
    /// outlived its walk is recognised rather than applied to the wrong queue.
    public let identifier: UUID
    public let limits: Limits
    public private(set) var queue: [Pending]
    public private(set) var directoriesListed: Int

    public init(serverIDs: [UUID], limits: Limits = .default) {
        identifier = UUID()
        self.limits = limits
        queue = serverIDs.map { Pending(serverID: $0, path: RemotePath.root, depth: 0) }
        directoriesListed = 0
    }

    /// The directory to list next, or nil when the walk is over.
    public var current: Pending? {
        guard directoriesListed < limits.maximumDirectories else { return nil }
        return queue.first
    }

    public var isFinished: Bool { current == nil }

    /// Records that `current` was listed and found these subdirectories.
    ///
    /// Subdirectories beyond the depth limit are not queued: they are listed
    /// by Finder when someone opens them, as everything was before this.
    public mutating func advance(subdirectories: [String]) {
        guard let listed = queue.first else { return }
        queue.removeFirst()
        directoriesListed += 1
        guard listed.depth < limits.maximumDepth else { return }
        queue += subdirectories.sorted().map {
            Pending(serverID: listed.serverID, path: RemotePath.join(listed.path, $0), depth: listed.depth + 1)
        }
    }

    /// Records that `current` could not be listed. The branch is dropped and
    /// the walk goes on; one unreadable directory is not a reason to index
    /// nothing else.
    public mutating func skipCurrent() {
        guard !queue.isEmpty else { return }
        queue.removeFirst()
        directoriesListed += 1
    }

    // MARK: - Page tokens

    /// What the system hands back to ask for the next page. The walk it
    /// belongs to, and how far along it was, so a stale token is detectable.
    public struct Token: Equatable, Sendable, Codable {
        public let walkIdentifier: UUID
        public let directoriesListed: Int
    }

    public var token: Token {
        Token(walkIdentifier: identifier, directoriesListed: directoriesListed)
    }

    /// Whether a token names this walk at its present step. Anything else —
    /// another walk, or a step this walk has already passed — means the
    /// system and the file disagree, and the file is discarded in favour of a
    /// fresh walk rather than resumed from the wrong place.
    public func matches(_ token: Token) -> Bool {
        token.walkIdentifier == identifier && token.directoriesListed == directoriesListed
    }

    public static func encode(_ token: Token) -> Data {
        (try? JSONEncoder().encode(token)) ?? Data()
    }

    public static func decode(_ data: Data) -> Token? {
        try? JSONDecoder().decode(Token.self, from: data)
    }
}
