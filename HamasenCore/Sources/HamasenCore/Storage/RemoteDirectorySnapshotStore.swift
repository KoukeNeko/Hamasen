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

/// Where the record of what each directory last looked like lives.
///
/// In the app group because both sides write it: the extension when it lists
/// a directory for Finder or for the working set, the app when it polls. A
/// record only one of them could see would report the other's listings as
/// changes.
public struct RemoteDirectorySnapshotStore: Sendable {
    private let fileURL: URL

    public init(appGroupIdentifier: String = SharedConstants.appGroupIdentifier) throws {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw ServerConfigStore.StoreError.appGroupContainerUnavailable(groupIdentifier: appGroupIdentifier)
        }
        self.fileURL = containerURL.appendingPathComponent(SharedConstants.remoteDirectorySnapshotFileName)
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() -> RemoteDirectorySnapshot {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(RemoteDirectorySnapshot.self, from: data)
        else { return RemoteDirectorySnapshot() }
        return snapshot
    }

    public func save(_ snapshot: RemoteDirectorySnapshot) throws {
        try JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
    }

    /// Records a listing and reports what changed, in one step.
    ///
    /// Read and write are not separable here: the extension lists directories
    /// from several tasks at once, and a read-modify-write split between them
    /// loses whichever listing finishes second.
    @discardableResult
    public func record(
        _ items: [RemoteItem], serverID: UUID, directoryPath: String
    ) -> RemoteDirectorySnapshot.Change {
        var snapshot = load()
        let change = snapshot.record(items, serverID: serverID, directoryPath: directoryPath)
        try? save(snapshot)
        return change
    }
}
