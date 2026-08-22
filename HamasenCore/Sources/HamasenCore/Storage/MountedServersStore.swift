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

/// Persists which servers are currently shown in Finder (mounted), separate
/// from the server configurations so no Codable migration is needed.
/// Written by the app, read by the File Provider extension.
public struct MountedServersStore: Sendable {
    private let fileURL: URL

    /// Standard initializer backed by the App Group container.
    public init(appGroupIdentifier: String = SharedConstants.appGroupIdentifier) throws {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw ServerConfigStore.StoreError.appGroupContainerUnavailable(groupIdentifier: appGroupIdentifier)
        }
        self.fileURL = containerURL.appendingPathComponent(SharedConstants.mountedServersFileName)
    }

    /// Test initializer: uses an arbitrary file location.
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func loadMountedServerIDs() throws -> Set<UUID> {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(Set<UUID>.self, from: data)
    }

    public func saveMountedServerIDs(_ serverIDs: Set<UUID>) throws {
        let data = try JSONEncoder().encode(serverIDs)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Takes one server out of the mounted set and returns what remains.
    ///
    /// Both the app and the File Provider extension unmount, so the
    /// read-modify-write lives here rather than in each of them.
    @discardableResult
    public func removeMountedServer(_ serverID: UUID) throws -> Set<UUID> {
        var mountedServerIDs = try loadMountedServerIDs()
        guard mountedServerIDs.remove(serverID) != nil else { return mountedServerIDs }
        try saveMountedServerIDs(mountedServerIDs)
        return mountedServerIDs
    }
}
