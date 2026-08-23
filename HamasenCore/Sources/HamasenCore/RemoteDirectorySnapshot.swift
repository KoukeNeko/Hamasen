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

/// What one remote directory looked like the last time it was listed.
///
/// Nothing here has a change feed — no protocol Hamasen speaks does — so the
/// only way to know a file appeared is to have written down what was there
/// before. This is that record, and the diff against a fresh listing is what
/// a notification is made of.
public struct RemoteDirectorySnapshot: Equatable, Sendable, Codable {
    /// Name to a token that changes whenever anything the user would notice
    /// changes: it appeared, it grew, it was edited.
    ///
    /// A directory's token deliberately excludes its size — servers report it
    /// inconsistently, and a directory whose size "changed" every listing
    /// would announce itself forever.
    public typealias Entries = [String: String]

    public private(set) var directories: [String: Entries]

    public init(directories: [String: Entries] = [:]) {
        self.directories = directories
    }

    public static func token(for item: RemoteItem) -> String {
        let modified = item.modificationDate.map { String(Int($0.timeIntervalSince1970)) } ?? ""
        return item.isDirectory
            ? "d\u{0}\(modified)"
            : "f\u{0}\(item.size)\u{0}\(modified)"
    }

    public static func entries(of items: [RemoteItem]) -> Entries {
        Dictionary(items.map { ($0.name, token(for: $0)) }, uniquingKeysWith: { first, _ in first })
    }

    /// Everything that changed in one directory since it was last recorded.
    public struct Change: Equatable, Sendable {
        public let serverID: UUID
        public let directoryPath: String
        public let addedNames: [String]
        public let updatedNames: [String]
        public let removedNames: [String]

        public var isEmpty: Bool {
            addedNames.isEmpty && updatedNames.isEmpty && removedNames.isEmpty
        }

        public var totalCount: Int {
            addedNames.count + updatedNames.count + removedNames.count
        }
    }

    private static func key(serverID: UUID, directoryPath: String) -> String {
        "\(serverID.uuidString)\u{0}\(directoryPath)"
    }

    public func entries(serverID: UUID, directoryPath: String) -> Entries? {
        directories[Self.key(serverID: serverID, directoryPath: directoryPath)]
    }

    /// Records a fresh listing and reports what it changed.
    ///
    /// A directory recorded for the first time reports nothing. Everything in
    /// it is new to this record but none of it is new to the server, and
    /// announcing a hundred files the moment a folder is first seen is how a
    /// notification becomes something people turn off.
    @discardableResult
    public mutating func record(
        _ items: [RemoteItem], serverID: UUID, directoryPath: String
    ) -> Change {
        let key = Self.key(serverID: serverID, directoryPath: directoryPath)
        let fresh = Self.entries(of: items)
        defer { directories[key] = fresh }

        guard let previous = directories[key] else {
            return Change(
                serverID: serverID, directoryPath: directoryPath,
                addedNames: [], updatedNames: [], removedNames: [])
        }
        return Change(
            serverID: serverID,
            directoryPath: directoryPath,
            addedNames: fresh.keys.filter { previous[$0] == nil }.sorted(),
            updatedNames: fresh.keys
                .filter { previous[$0] != nil && previous[$0] != fresh[$0] }.sorted(),
            removedNames: previous.keys.filter { fresh[$0] == nil }.sorted())
    }

    /// Drops what is known about a server, for one that is unmounted or
    /// removed. Left behind, its directories would be reported as new the
    /// next time it came back.
    public mutating func forget(serverID: UUID) {
        let prefix = "\(serverID.uuidString)\u{0}"
        directories = directories.filter { !$0.key.hasPrefix(prefix) }
    }

    /// Keeps only the servers still mounted.
    public mutating func keepOnly(serverIDs: Set<UUID>) {
        let keep = Set(serverIDs.map { "\($0.uuidString)\u{0}" })
        directories = directories.filter { entry in
            keep.contains { entry.key.hasPrefix($0) }
        }
    }

    public var directoryCount: Int { directories.count }
}
