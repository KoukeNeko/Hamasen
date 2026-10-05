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
/// Written by the app and by the File Provider extension (unmounting from
/// Finder), so every mutation is a read-modify-write under a cross-process
/// lock, and callers change the set by delta rather than writing back a copy
/// they read earlier.
public struct MountedServersStore: Sendable {
    private let fileURL: URL
    private let lock: FileLock

    /// Standard initializer backed by the App Group container.
    public init(appGroupIdentifier: String = SharedConstants.appGroupIdentifier) throws {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw ServerConfigStore.StoreError.appGroupContainerUnavailable(groupIdentifier: appGroupIdentifier)
        }
        self.init(fileURL: containerURL.appendingPathComponent(SharedConstants.mountedServersFileName))
    }

    /// Test initializer: uses an arbitrary file location.
    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.lock = FileLock(lockURL: fileURL.appendingPathExtension("lock"))
    }

    /// Not locked: a write replaces the file atomically, so a read sees the
    /// set before or after it and never half of one.
    public func loadMountedServerIDs() throws -> Set<UUID> {
        try load()
    }

    /// Replaces the whole set. For a caller that owns it outright; one that
    /// only means to mount or unmount a server uses `addMountedServers` or
    /// `removeMountedServer`, which cannot undo the other process's change.
    public func saveMountedServerIDs(_ serverIDs: Set<UUID>) throws {
        try lock.withLock { try save(serverIDs) }
    }

    /// Adds servers to the mounted set and returns the resulting set.
    @discardableResult
    public func addMountedServers(_ serverIDs: some Sequence<UUID>) throws -> Set<UUID> {
        try lock.withLock {
            var mountedServerIDs = try load()
            let before = mountedServerIDs
            mountedServerIDs.formUnion(serverIDs)
            if mountedServerIDs != before {
                try save(mountedServerIDs)
            }
            return mountedServerIDs
        }
    }

    /// Takes one server out of the mounted set and returns what remains.
    ///
    /// Both the app and the File Provider extension unmount, so the
    /// read-modify-write lives here rather than in each of them.
    @discardableResult
    public func removeMountedServer(_ serverID: UUID) throws -> Set<UUID> {
        try lock.withLock {
            var mountedServerIDs = try load()
            guard mountedServerIDs.remove(serverID) != nil else { return mountedServerIDs }
            try save(mountedServerIDs)
            return mountedServerIDs
        }
    }

    private func load() throws -> Set<UUID> {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode(Set<UUID>.self, from: Data(contentsOf: fileURL))
    }

    private func save(_ serverIDs: Set<UUID>) throws {
        try JSONEncoder().encode(serverIDs).write(to: fileURL, options: .atomic)
    }
}
