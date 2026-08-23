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

/// The directories whose contents the system has to be told about again.
///
/// A replicated extension has one channel for changes: the working set's
/// change enumeration. A signal for any other container is ignored — the
/// header says so in as many words. So whoever learns that a directory's
/// contents changed, the pin action in the extension or the poll in the app,
/// writes the directory here and signals the working set; the working-set
/// enumerator lists what is here and reports it.
///
/// Both processes write the file, and a write can lose another's entry. That
/// costs a refresh, not a change: whatever noticed it notices it again.
public struct DirectoryRefreshQueue: Sendable {
    public struct Entry: Hashable, Codable, Sendable {
        public let serverID: UUID
        public let path: String

        public init(serverID: UUID, path: String) {
            self.serverID = serverID
            self.path = path
        }
    }

    private let fileURL: URL

    public init(appGroupIdentifier: String = SharedConstants.appGroupIdentifier) throws {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw ServerConfigStore.StoreError.appGroupContainerUnavailable(groupIdentifier: appGroupIdentifier)
        }
        self.fileURL = containerURL.appendingPathComponent(SharedConstants.directoryRefreshQueueFileName)
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func enqueue(_ entries: some Sequence<Entry>) throws {
        var queued = try load()
        queued.formUnion(entries)
        try JSONEncoder().encode(queued).write(to: fileURL, options: .atomic)
    }

    /// Takes everything queued, leaving the queue empty.
    public func drain() throws -> Set<Entry> {
        let queued = try load()
        if !queued.isEmpty {
            try FileManager.default.removeItem(at: fileURL)
        }
        return queued
    }

    private func load() throws -> Set<Entry> {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode(Set<Entry>.self, from: Data(contentsOf: fileURL))
    }
}
