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
/// The walk reaches the system two ways. The first import pages through it
/// (`enumerateItems`), which is all a system with no anchor can do. After
/// that it goes out as change batches — one directory per `enumerateChanges`,
/// the anchor carrying the token — because answering an expired anchor to
/// start a walk makes the system drop its working set and import it again,
/// and while a domain is importing it downloads nothing in the background.
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

    /// Limits that keep the walk from becoming the server's whole day, or
    /// this Mac's.
    ///
    /// Every directory is one listing request: on S3 a billed operation, on
    /// SFTP load on somebody's machine. Every item listed is a placeholder
    /// the system has to create and Spotlight has to index, at a few thousand
    /// a minute; a data archive with a thousand files per folder reaches a
    /// hundred thousand long before it reaches two thousand directories.
    /// Both budgets are per server, or one server with a node_modules in it
    /// would spend them and leave the others unlisted.
    public struct Limits: Equatable, Sendable, Codable {
        public let maximumDepth: Int
        public let maximumDirectories: Int
        public let maximumItems: Int

        public init(maximumDepth: Int, maximumDirectories: Int, maximumItems: Int) {
            self.maximumDepth = maximumDepth
            self.maximumDirectories = maximumDirectories
            self.maximumItems = maximumItems
        }

        public static let `default` = Limits(maximumDepth: 6, maximumDirectories: 2_000, maximumItems: 20_000)
    }

    /// Distinguishes this walk from the one before it, so a page token that
    /// outlived its walk is recognised rather than applied to the wrong queue.
    public let identifier: UUID
    public let limits: Limits
    /// The servers the walk was started over, so a walk from before a
    /// server opted out is not resumed for it.
    public let serverIDs: [UUID]
    public let startedAt: Date
    public private(set) var completedAt: Date?
    public private(set) var queue: [Pending]
    public private(set) var directoriesListed: Int
    private var directoriesListedPerServer: [UUID: Int]
    private var itemsListedPerServer: [UUID: Int]

    /// How long a finished walk stays current. Finder browsing and the change
    /// watcher keep the opened folders fresh in between; the rest of the tree
    /// is re-listed this often, at one billed request per directory on S3.
    public static let repeatInterval: TimeInterval = 24 * 60 * 60

    public init(serverIDs: [UUID], limits: Limits = .default, startedAt: Date = Date()) {
        identifier = UUID()
        self.limits = limits
        self.serverIDs = serverIDs
        self.startedAt = startedAt
        queue = serverIDs.map { Pending(serverID: $0, path: RemotePath.root, depth: 0) }
        directoriesListed = 0
        directoriesListedPerServer = [:]
        itemsListedPerServer = [:]
    }

    public mutating func markCompleted(at date: Date = Date()) {
        completedAt = date
    }

    /// Whether a new walk should replace this one: it finished, or was
    /// started and then abandoned, longer ago than the interval.
    public func isStale(at now: Date) -> Bool {
        now.timeIntervalSince(completedAt ?? startedAt) >= Self.repeatInterval
    }

    /// The directory to list next, or nil when the walk is over.
    public var current: Pending? { queue.first }

    public var isFinished: Bool { current == nil }

    /// Records that `current` was listed, held `itemCount` entries, and
    /// found these subdirectories among them.
    ///
    /// Subdirectories beyond the depth limit are not queued: they are listed
    /// by Finder when someone opens them, as everything was before this.
    /// Neither are hidden ones: Spotlight indexes nothing under a dot
    /// directory, and a home directory's `.cache` and `.vscode-server` can
    /// take the whole budget on their own — 2,862 of one server's 2,000
    /// listings went there before this check existed.
    public mutating func advance(itemCount: Int, subdirectories: [String]) {
        guard let listed = queue.first else { return }
        guard countListing(of: listed, itemCount: itemCount), listed.depth < limits.maximumDepth else { return }
        queue += subdirectories.filter { !Self.isHidden($0) }.sorted().map {
            Pending(serverID: listed.serverID, path: RemotePath.join(listed.path, $0), depth: listed.depth + 1)
        }
    }

    private static let hiddenNamePrefix = "."

    private static func isHidden(_ name: String) -> Bool {
        name.hasPrefix(hiddenNamePrefix)
    }

    /// Records that `current` could not be listed. The branch is dropped and
    /// the walk goes on; one unreadable directory is not a reason to index
    /// nothing else.
    public mutating func skipCurrent() {
        guard let skipped = queue.first else { return }
        _ = countListing(of: skipped, itemCount: 0)
    }

    /// Takes `pending` off the queue and charges it to its server. Returns
    /// whether that server has budget left; when it has not, whatever else
    /// was queued for it goes too, so the other servers' entries come up.
    private mutating func countListing(of pending: Pending, itemCount: Int) -> Bool {
        queue.removeFirst()
        directoriesListed += 1
        let directoriesOnServer = directoriesListedPerServer[pending.serverID, default: 0] + 1
        let itemsOnServer = itemsListedPerServer[pending.serverID, default: 0] + itemCount
        directoriesListedPerServer[pending.serverID] = directoriesOnServer
        itemsListedPerServer[pending.serverID] = itemsOnServer
        guard directoriesOnServer < limits.maximumDirectories, itemsOnServer < limits.maximumItems else {
            queue.removeAll { $0.serverID == pending.serverID }
            return false
        }
        return true
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

    /// Whether a token comes from this walk, at whatever step. For change
    /// batches, where the extension may have saved a step the system never
    /// recorded: resuming re-lists at most one directory, where refusing
    /// would abandon the walk until the next day's.
    public func belongs(to token: Token) -> Bool {
        token.walkIdentifier == identifier
    }

    public static func encode(_ token: Token) -> Data {
        (try? JSONEncoder().encode(token)) ?? Data()
    }

    public static func decode(_ data: Data) -> Token? {
        try? JSONDecoder().decode(Token.self, from: data)
    }
}
