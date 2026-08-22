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

/// Tracks what changed in the mounted-server list between two enumerations.
///
/// The File Provider extension has no state of its own between calls, so the
/// previous list is carried inside the sync anchor the system hands back.
public enum ServerListChangeTracker {
    /// Server identifier to the token describing its Finder folder. Detects
    /// additions, removals, renames, and any other change the folder itself
    /// carries — the storage mode, which decides its content policy.
    public typealias Snapshot = [String: String]

    public struct Diff: Equatable, Sendable {
        /// Servers that appeared or were renamed.
        public let updated: [ServerConfig]
        /// Servers that are no longer mounted.
        public let removedServerIDs: [String]

        public var isEmpty: Bool { updated.isEmpty && removedServerIDs.isEmpty }
    }

    public static func snapshot(of configs: [ServerConfig]) -> Snapshot {
        Dictionary(
            configs.map { ($0.id.uuidString, $0.finderItemToken) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Encodes a snapshot for use as a sync anchor. Sorted keys keep the
    /// encoding stable so an unchanged list produces an identical anchor.
    public static func encode(_ snapshot: Snapshot) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(snapshot)) ?? Data()
    }

    /// Decodes a previously encoded snapshot; an unreadable anchor is treated
    /// as "nothing known yet", which makes every server look new.
    public static func decode(_ data: Data) -> Snapshot {
        (try? JSONDecoder().decode(Snapshot.self, from: data)) ?? [:]
    }

    public static func diff(previous: Snapshot, current configs: [ServerConfig]) -> Diff {
        let current = snapshot(of: configs)
        let updated = configs.filter { previous[$0.id.uuidString] != $0.finderItemToken }
        let removedServerIDs = previous.keys.filter { current[$0] == nil }.sorted()
        return Diff(updated: updated, removedServerIDs: removedServerIDs)
    }
}
