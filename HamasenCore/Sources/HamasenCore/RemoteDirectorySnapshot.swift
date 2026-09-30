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
///
/// One record per directory, stored on its own (`RemoteDirectorySnapshotStore`):
/// recording a listing must cost the size of that directory, not of every
/// directory ever listed.
public struct RemoteDirectorySnapshot: Equatable, Sendable, Codable {
    /// Name to a token that changes whenever anything the user would notice
    /// changes: it appeared, it grew, it was edited.
    ///
    /// A directory's token deliberately excludes its size — servers report it
    /// inconsistently, and a directory whose size "changed" every listing
    /// would announce itself forever.
    public typealias Entries = [String: String]

    /// Stored beside the entries because the file name is a hash of it.
    public let path: String
    public let entries: Entries

    public init(path: String, entries: Entries) {
        self.path = path
        self.entries = entries
    }

    public init(path: String, items: [RemoteItem]) {
        self.init(path: path, entries: Self.entries(of: items))
    }

    public static func token(for item: RemoteItem) -> String {
        if item.isDirectory {
            let modified = item.modificationDate.map { String(Int($0.timeIntervalSince1970)) } ?? ""
            return "d\u{0}\(modified)"
        }
        // The same derivation the File Provider item version uses, so this
        // record and the system agree on what "changed" means.
        return "f\u{0}\(item.contentVersionToken)"
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

    /// What a fresh listing changed against the record it is replacing.
    ///
    /// A directory with no record reports nothing. Everything in it is new to
    /// the record but none of it is new to the server, and announcing a
    /// hundred files the moment a folder is first seen is how a notification
    /// becomes something people turn off. It also means a deletion cannot be
    /// known for a directory that was never recorded.
    public static func change(
        from previous: RemoteDirectorySnapshot?, to fresh: RemoteDirectorySnapshot, serverID: UUID
    ) -> Change {
        guard let previous = previous?.entries else {
            return Change(
                serverID: serverID, directoryPath: fresh.path,
                addedNames: [], updatedNames: [], removedNames: [])
        }
        let current = fresh.entries
        return Change(
            serverID: serverID,
            directoryPath: fresh.path,
            addedNames: current.keys.filter { previous[$0] == nil }.sorted(),
            updatedNames: current.keys
                .filter { previous[$0] != nil && previous[$0] != current[$0] }.sorted(),
            removedNames: previous.keys.filter { current[$0] == nil }.sorted())
    }
}
