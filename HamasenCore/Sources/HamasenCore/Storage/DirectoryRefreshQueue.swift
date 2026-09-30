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
/// Both processes write the file, so every change to it is a read-modify-write
/// under a lock. An entry leaves the queue only once the caller says it was
/// reported (`remove`); one taken off up front is lost with the process that
/// took it, or with a server that was down at the time.
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
    private let lock: FileLock

    public init(appGroupIdentifier: String = SharedConstants.appGroupIdentifier) throws {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw ServerConfigStore.StoreError.appGroupContainerUnavailable(groupIdentifier: appGroupIdentifier)
        }
        self.init(fileURL: containerURL.appendingPathComponent(SharedConstants.directoryRefreshQueueFileName))
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.lock = FileLock(lockURL: fileURL.appendingPathExtension("lock"))
    }

    public func enqueue(_ entries: some Sequence<Entry>) throws {
        try lock.withLock {
            var queued = try load()
            queued.formUnion(entries)
            try store(queued)
        }
    }

    /// What is queued, leaving it there.
    public func pending() throws -> Set<Entry> {
        try lock.withLock { try load() }
    }

    /// Takes reported entries off the queue. Anything enqueued since
    /// `pending()` was read stays.
    public func remove(_ entries: some Sequence<Entry>) throws {
        try lock.withLock {
            var queued = try load()
            queued.subtract(entries)
            try store(queued)
        }
    }

    /// Takes everything queued, leaving the queue empty.
    public func drain() throws -> Set<Entry> {
        try lock.withLock {
            let queued = try load()
            try store([])
            return queued
        }
    }

    private func store(_ queued: Set<Entry>) throws {
        if queued.isEmpty {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        } else {
            try JSONEncoder().encode(queued).write(to: fileURL, options: .atomic)
        }
    }

    private func load() throws -> Set<Entry> {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            return try JSONDecoder().decode(Set<Entry>.self, from: Data(contentsOf: fileURL))
        } catch is DecodingError {
            // A queue nobody can read would block every later refresh for
            // good. What it held was a set of hints that whatever noticed
            // them notices again.
            return []
        }
    }
}
