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

import Crypto
import Foundation

/// Where the record of what each directory last looked like lives.
///
/// In the app group because both sides write it: the extension when it lists
/// a directory for Finder or for the working set, the app when it polls. A
/// record only one of them could see would report the other's listings as
/// changes.
///
/// One small file per directory, `<root>/<server>/<hash of path>.json`. A
/// single file for everything grew to tens of megabytes on a Mac that had
/// browsed a few thousand folders, and every listing, refresh and poll read
/// and rewrote all of it. Now recording a directory touches that directory's
/// file alone.
///
/// Read-modify-write on a file is serialised across both processes by a lock
/// per server; reads take no lock, because a write replaces the file whole.
public struct RemoteDirectorySnapshotStore: Sendable {
    /// A directory neither recorded nor observed for this long is dropped.
    /// Coming back to it later costs one silent first record.
    public static let retention: TimeInterval = 30 * 24 * 60 * 60

    /// How often a record call may spend time looking for records to drop.
    private static let pruneInterval: TimeInterval = 24 * 60 * 60

    private static let pruneMarkerName = ".last-pruned"
    private static let lockExtension = "lock"

    private static let log = HamasenLog(category: "directory-record")

    private let rootURL: URL

    public init(appGroupIdentifier: String = SharedConstants.appGroupIdentifier) throws {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw ServerConfigStore.StoreError.appGroupContainerUnavailable(groupIdentifier: appGroupIdentifier)
        }
        self.init(containerURL: containerURL)
    }

    /// The store inside an App Group container, clearing the record it
    /// replaced.
    init(containerURL: URL) {
        self.init(directoryURL: containerURL.appendingPathComponent(SharedConstants.remoteDirectoriesDirectoryName))
        Self.removeLegacyFile(in: containerURL)
    }

    public init(directoryURL: URL) {
        self.rootURL = directoryURL
    }

    /// The single-file record this replaced. Its contents are not converted:
    /// a directory recorded afresh reports no changes, which is all losing
    /// the old baselines costs.
    private static func removeLegacyFile(in containerURL: URL) {
        let legacyURL = containerURL.appendingPathComponent(SharedConstants.legacyRemoteDirectorySnapshotFileName)
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: legacyURL)
        } catch {
            // Both processes try on first use; the loser finds it gone.
            guard !FileManager.default.fileExists(atPath: legacyURL.path) else {
                log.error("Could not remove the old directory record: \(error.localizedDescription)")
                return
            }
        }
    }

    // MARK: - Reading and recording

    /// The record of one directory, or nil when there is none — or when the
    /// file cannot be read, which for a baseline is the same as never having
    /// seen the directory.
    public func snapshot(serverID: UUID, directoryPath: String) -> RemoteDirectorySnapshot? {
        guard let data = try? Data(contentsOf: fileURL(serverID: serverID, directoryPath: directoryPath)),
              let snapshot = try? JSONDecoder().decode(RemoteDirectorySnapshot.self, from: data),
              snapshot.path == directoryPath
        else { return nil }
        return snapshot
    }

    /// Records a listing and reports what changed, in one step.
    ///
    /// Read and write are not separable here: the extension lists directories
    /// from several tasks at once, the app polls at the same time, and a
    /// read-modify-write split between them loses whichever listing finishes
    /// second.
    @discardableResult
    public func record(
        _ items: [RemoteItem], serverID: UUID, directoryPath: String
    ) throws -> RemoteDirectorySnapshot.Change {
        let fresh = RemoteDirectorySnapshot(path: directoryPath, items: items)
        let change = try serverLock(serverID).withLock {
            let change = RemoteDirectorySnapshot.change(
                from: snapshot(serverID: serverID, directoryPath: directoryPath), to: fresh, serverID: serverID)
            try write(fresh, serverID: serverID)
            return change
        }
        pruneIfDue()
        return change
    }

    /// Reports what a listing changed without recording it, except for a
    /// directory with no record, which gets its baseline so the next look has
    /// something to compare against.
    ///
    /// For the poll, which must leave the record for the extension to write
    /// when it brings the system up to date: writing it first would leave the
    /// extension nothing to report, and a deleted file would stay in Finder.
    public func observe(
        _ items: [RemoteItem], serverID: UUID, directoryPath: String
    ) throws -> RemoteDirectorySnapshot.Change {
        let fresh = RemoteDirectorySnapshot(path: directoryPath, items: items)
        return try serverLock(serverID).withLock {
            let previous = snapshot(serverID: serverID, directoryPath: directoryPath)
            let change = RemoteDirectorySnapshot.change(from: previous, to: fresh, serverID: serverID)
            if previous == nil {
                try write(fresh, serverID: serverID)
            } else if change.isEmpty {
                // Looked at and still current: not a candidate for pruning.
                try FileManager.default.setAttributes(
                    [.modificationDate: Date()],
                    ofItemAtPath: fileURL(serverID: serverID, directoryPath: directoryPath).path)
            }
            return change
        }
    }

    // MARK: - Removing

    /// Drops what is known about a server, for one that is unmounted or
    /// removed. Left behind, its directories would be reported as new the
    /// next time it came back.
    public func forget(serverID: UUID) throws {
        try serverLock(serverID).withLock {
            try removeIfPresent(serverDirectoryURL(serverID))
        }
    }

    /// Keeps only the servers still mounted.
    public func keepOnly(serverIDs: Set<UUID>) throws {
        for serverID in try recordedServerIDs() where !serverIDs.contains(serverID) {
            try forget(serverID: serverID)
        }
    }

    /// Drops the records not recorded or observed for `retention`. Returns
    /// how many went.
    @discardableResult
    public func prune(now: Date = Date()) throws -> Int {
        let cutoff = now.addingTimeInterval(-Self.retention)
        var removedCount = 0
        for serverID in try recordedServerIDs() {
            let candidates = try expiredRecords(of: serverID, before: cutoff)
            guard !candidates.isEmpty else { continue }
            // Checked again under the lock: a record written since the scan
            // is fresh, and removing it would lose the baseline.
            try serverLock(serverID).withLock {
                for url in candidates where Self.modificationDate(of: url).map({ $0 < cutoff }) ?? false {
                    try removeIfPresent(url)
                    removedCount += 1
                }
            }
        }
        return removedCount
    }

    /// At most once a day, and never able to fail a listing: an unpruned
    /// record costs disk, nothing else.
    private func pruneIfDue() {
        let markerURL = rootURL.appendingPathComponent(Self.pruneMarkerName)
        if let lastPruned = Self.modificationDate(of: markerURL),
           Date().timeIntervalSince(lastPruned) < Self.pruneInterval {
            return
        }
        do {
            // The marker first, so a slow prune is not started again by the
            // next listing.
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try Data().write(to: markerURL)
            try prune()
        } catch {
            Self.log.error("Could not prune the directory record: \(error.localizedDescription)")
        }
    }

    // MARK: - Files

    private func recordedServerIDs() throws -> [UUID] {
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: rootURL.path).compactMap(UUID.init(uuidString:))
    }

    private func expiredRecords(of serverID: UUID, before cutoff: Date) throws -> [URL] {
        let directoryURL = serverDirectoryURL(serverID)
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: [.contentModificationDateKey]
        ).filter { url in
            Self.modificationDate(of: url).map { $0 < cutoff } ?? false
        }
    }

    private func write(_ snapshot: RemoteDirectorySnapshot, serverID: UUID) throws {
        try FileManager.default.createDirectory(at: serverDirectoryURL(serverID), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(
            to: fileURL(serverID: serverID, directoryPath: snapshot.path), options: .atomic)
    }

    private func removeIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func serverLock(_ serverID: UUID) -> FileLock {
        FileLock(lockURL: rootURL.appendingPathComponent("\(serverID.uuidString).\(Self.lockExtension)"))
    }

    private func serverDirectoryURL(_ serverID: UUID) -> URL {
        rootURL.appendingPathComponent(serverID.uuidString, isDirectory: true)
    }

    private func fileURL(serverID: UUID, directoryPath: String) -> URL {
        let digest = SHA256.hash(data: Data(directoryPath.utf8))
        let name = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return serverDirectoryURL(serverID).appendingPathComponent("\(name).json")
    }

    private static func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
