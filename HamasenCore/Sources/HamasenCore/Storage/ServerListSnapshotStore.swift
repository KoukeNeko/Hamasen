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

/// The server lists that sync anchors refer to.
///
/// An anchor carries a digest and nothing else, so the list it stands for has
/// to be somewhere the extension can find it on the next call. The system
/// hands back the latest anchor it was given, sometimes one or two behind, so
/// a few are kept and no more.
public struct ServerListSnapshotStore: Sendable {
    static let keptCount = 5

    private let directoryURL: URL

    public init(appGroupIdentifier: String = SharedConstants.appGroupIdentifier) throws {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw ServerConfigStore.StoreError.appGroupContainerUnavailable(groupIdentifier: appGroupIdentifier)
        }
        self.init(directoryURL: containerURL.appendingPathComponent(SharedConstants.serverListSnapshotsDirectoryName))
    }

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    /// Stores the snapshot and returns the digest that names it.
    ///
    /// Written again even when present, which refreshes its age: the one an
    /// anchor was just made from must outlast the ones before it.
    public func save(_ snapshot: ServerListChangeTracker.Snapshot) throws -> String {
        let digest = ServerListChangeTracker.digest(of: snapshot)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try ServerListChangeTracker.encode(snapshot).write(to: fileURL(digest), options: .atomic)
        try discardOldest()
        return digest
    }

    /// The snapshot a digest names, or nil when it was never stored or has
    /// been discarded.
    public func load(digest: String) -> ServerListChangeTracker.Snapshot? {
        guard let data = try? Data(contentsOf: fileURL(digest)) else { return nil }
        return try? JSONDecoder().decode(ServerListChangeTracker.Snapshot.self, from: data)
    }

    private func discardOldest() throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: [.contentModificationDateKey])
        let newestFirst = files.sorted {
            Self.modificationDate(of: $0) > Self.modificationDate(of: $1)
        }
        for url in newestFirst.dropFirst(Self.keptCount) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// The digest is hex from this process's own hashing, but it arrives from
    /// the system in an anchor; anything else must not name a path.
    private func fileURL(_ digest: String) -> URL {
        let safeName = digest.filter(\.isHexDigit)
        return directoryURL.appendingPathComponent("\(safeName).json")
    }
}
