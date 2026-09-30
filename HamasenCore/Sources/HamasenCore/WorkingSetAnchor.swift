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

/// What the working set's sync anchor stands for: the server list the system
/// last heard about, and how far the walk had got.
///
/// Both by reference. The system refuses an anchor over 500 bytes, and a
/// server list of a handful of servers with long names is more than that, so
/// the list is a digest of a snapshot kept in the App Group.
public struct WorkingSetAnchor: Equatable, Sendable, Codable {
    /// Digest of the server list, per `ServerListChangeTracker.digest`.
    public let serverList: String
    /// The walk as of the last step reported. Kept after the walk finishes,
    /// so the anchor a finished walk ends on differs from the one it began
    /// at: a batch that reports changes under an unchanged anchor reads as
    /// "nothing to see".
    public let walk: WorkingSetWalk.Token?
    /// Marks a batch that reported something when nothing else in the anchor
    /// moved — a queued refresh, with no walk step and no server change —
    /// for the same reason: the header expects such a batch to end on a
    /// different anchor.
    public let batch: String?

    public init(serverList: String, walk: WorkingSetWalk.Token?, batch: String? = nil) {
        self.serverList = serverList
        self.walk = walk
        self.batch = batch
    }

    private enum CodingKeys: String, CodingKey {
        case serverList = "l"
        case walk = "w"
        case batch = "b"
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)) ?? Data()
    }

    /// nil for anything that is not an anchor of this shape, which includes
    /// the ones an earlier version made.
    public static func decode(_ data: Data) -> WorkingSetAnchor? {
        try? JSONDecoder().decode(WorkingSetAnchor.self, from: data)
    }
}
