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

/// When each local copy was last wanted, so automatic cleaning can drop what
/// nobody has used for a while.
///
/// The system does not tell a provider when a file is read, so three signals
/// stand in for it, and the latest of them is the answer:
///
/// - the date Finder stamps on an item when it is opened, which reaches the
///   extension as a change to `lastUsedDate`;
/// - when the extension downloaded the content;
/// - when the app first saw the copy, for content downloaded before any of
///   this was recorded — counted from then rather than treated as ancient,
///   which would have dropped everything on the first pass.
public struct ItemUsageStore: Sendable {
    public struct Usage: Codable, Equatable, Sendable {
        public var lastUsed: Date?
        public var downloaded: Date?
        public var firstSeen: Date?

        public init(lastUsed: Date? = nil, downloaded: Date? = nil, firstSeen: Date? = nil) {
            self.lastUsed = lastUsed
            self.downloaded = downloaded
            self.firstSeen = firstSeen
        }

        public var latest: Date? {
            [lastUsed, downloaded, firstSeen].compactMap { $0 }.max()
        }
    }

    /// Past this many entries the oldest go, so a long-lived mount cannot
    /// grow the file without bound. Entries for copies that were since
    /// dropped are pruned by the app as it measures.
    static let maximumEntries = 50_000

    private let fileURL: URL
    private let lock: FileLock

    public init(appGroupIdentifier: String = SharedConstants.appGroupIdentifier) throws {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw ServerConfigStore.StoreError.appGroupContainerUnavailable(groupIdentifier: appGroupIdentifier)
        }
        self.init(fileURL: containerURL.appendingPathComponent(SharedConstants.itemUsageFileName))
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.lock = FileLock(lockURL: fileURL.appendingPathExtension("lock"))
    }

    public func load() throws -> [String: Usage] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode([String: Usage].self, from: Data(contentsOf: fileURL))
    }

    public func recordUse(of identifier: String, at date: Date) throws {
        try update { $0[identifier, default: Usage()].lastUsed = date }
    }

    public func recordDownload(of identifier: String, at date: Date = Date()) throws {
        try update { $0[identifier, default: Usage()].downloaded = date }
    }

    /// Notes the copies seen for the first time and forgets those no longer
    /// on this Mac, in one write.
    public func reconcile(present identifiers: Set<String>, at date: Date = Date()) throws -> [String: Usage] {
        try update { usage in
            for identifier in identifiers where usage[identifier]?.firstSeen == nil {
                usage[identifier, default: Usage()].firstSeen = date
            }
            for identifier in usage.keys where !identifiers.contains(identifier) {
                usage[identifier] = nil
            }
        }
    }

    @discardableResult
    private func update(_ change: (inout [String: Usage]) -> Void) throws -> [String: Usage] {
        try lock.withLock {
            let before = (try? load()) ?? [:]
            var usage = before
            change(&usage)
            // Measuring runs every few seconds while a window shows usage;
            // most passes change nothing and should not rewrite the file.
            guard usage != before else { return usage }
            if usage.count > Self.maximumEntries {
                let excess = usage.count - Self.maximumEntries
                let oldest = usage.sorted { ($0.value.latest ?? .distantPast) < ($1.value.latest ?? .distantPast) }
                    .prefix(excess).map(\.key)
                oldest.forEach { usage[$0] = nil }
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            try encoder.encode(usage).write(to: fileURL, options: .atomic)
            return usage
        }
    }
}
