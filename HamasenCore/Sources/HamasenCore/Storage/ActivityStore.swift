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

/// What the extension is doing and has just done, for the app to show:
/// each file in flight, the transfers that finished, the conflicts it kept
/// both sides of, and how each server last answered.
///
/// The system reports one running total per direction for the whole domain,
/// which says how much is moving but not what or where. Only the extension
/// knows that, so it writes it here and posts `changeNotification`; the app
/// reads the file when told and on a slow timer in case a notification was
/// missed.
public struct ActivitySnapshot: Codable, Equatable, Sendable {
    public var transfers: [TransferRecord] = []
    /// Newest first.
    public var completed: [CompletedTransfer] = []
    /// Newest first.
    public var conflicts: [ConflictRecord] = []
    public var servers: [UUID: ServerHealth] = [:]

    public init() {}

    static let maximumCompleted = 30
    static let maximumConflicts = 30
}

public enum TransferDirection: String, Codable, Sendable {
    case upload
    case download
    /// From one server to another: down from the source, then up to the
    /// destination.
    case move
}

public struct TransferRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let serverID: UUID
    public let path: String
    public let direction: TransferDirection
    public var bytesTransferred: Int64
    public var totalBytes: Int64
    public let startedAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), serverID: UUID, path: String, direction: TransferDirection,
        bytesTransferred: Int64 = 0, totalBytes: Int64, startedAt: Date = Date(), updatedAt: Date = Date()
    ) {
        self.id = id
        self.serverID = serverID
        self.path = path
        self.direction = direction
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }

    public var fileName: String { RemotePath.name(of: path) }

    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        return min(Double(bytesTransferred) / Double(totalBytes), 1)
    }

    /// Bytes per second over the whole transfer so far; nil until there is
    /// enough of it to say.
    public var bytesPerSecond: Double? {
        let elapsed = updatedAt.timeIntervalSince(startedAt)
        guard elapsed >= 0.5, bytesTransferred > 0 else { return nil }
        return Double(bytesTransferred) / elapsed
    }

    /// At the average rate so far.
    public var secondsRemaining: TimeInterval? {
        secondsRemaining(at: bytesPerSecond)
    }

    /// An estimate past this says nothing a person can plan around, and is
    /// mostly a rate that has all but stopped.
    static let longestEstimate: TimeInterval = 99 * 60 * 60

    /// How long what is left takes at `rate` bytes per second; nil without a
    /// rate, with nothing left, or when the answer would be absurd.
    public func secondsRemaining(at rate: Double?) -> TimeInterval? {
        guard let rate, rate > 0, totalBytes > bytesTransferred else { return nil }
        let seconds = Double(totalBytes - bytesTransferred) / rate
        return seconds <= Self.longestEstimate ? seconds : nil
    }
}

public struct CompletedTransfer: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let serverID: UUID
    public let path: String
    public let direction: TransferDirection
    public let totalBytes: Int64
    public let finishedAt: Date
    /// nil when it succeeded.
    public let failure: String?

    public init(
        id: UUID, serverID: UUID, path: String, direction: TransferDirection, totalBytes: Int64,
        finishedAt: Date = Date(), failure: String? = nil
    ) {
        self.id = id
        self.serverID = serverID
        self.path = path
        self.direction = direction
        self.totalBytes = totalBytes
        self.finishedAt = finishedAt
        self.failure = failure
    }

    public var fileName: String { RemotePath.name(of: path) }
}

/// A local edit that met a newer version on the server, kept beside it as a
/// copy rather than written over it.
public struct ConflictRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let serverID: UUID
    /// The file both sides changed.
    public let path: String
    /// What the local edit was saved as, in the same folder.
    public let copyName: String
    public let date: Date

    public init(id: UUID = UUID(), serverID: UUID, path: String, copyName: String, date: Date = Date()) {
        self.id = id
        self.serverID = serverID
        self.path = path
        self.copyName = copyName
        self.date = date
    }

    public var fileName: String { RemotePath.name(of: path) }
}

/// How a server last answered whoever asked it something.
public struct ServerHealth: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case reachable
        /// The connection itself failed: no network, host down, timed out.
        case unreachable
        /// The server or provider refused the stored credentials or token.
        case signInRequired
    }

    public let state: State
    public let message: String?
    public let since: Date

    public init(state: State, message: String? = nil, since: Date = Date()) {
        self.state = state
        self.message = message
        self.since = since
    }
}

public struct ActivityStore: Sendable {
    /// Posted through the Darwin center after every write. Prefixed with the
    /// App Group, which is what lets a sandboxed process post and observe it.
    public static let changeNotification = "\(SharedConstants.appGroupIdentifier).activity"

    private let fileURL: URL
    private let lock: FileLock

    public init(appGroupIdentifier: String = SharedConstants.appGroupIdentifier) throws {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw ServerConfigStore.StoreError.appGroupContainerUnavailable(groupIdentifier: appGroupIdentifier)
        }
        self.init(fileURL: containerURL.appendingPathComponent(SharedConstants.activityFileName))
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.lock = FileLock(lockURL: fileURL.appendingPathExtension("lock"))
    }

    /// Not locked: writes replace the file atomically.
    public func load() throws -> ActivitySnapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return ActivitySnapshot() }
        return try Self.decoder.decode(ActivitySnapshot.self, from: Data(contentsOf: fileURL))
    }

    /// Changes the snapshot under the lock and tells the other process.
    @discardableResult
    public func update(_ change: (inout ActivitySnapshot) -> Void) throws -> ActivitySnapshot {
        let updated = try lock.withLock {
            // A file that cannot be decoded — written by a later version, or
            // damaged — is started over: it is a log of the last few minutes,
            // not anything to keep.
            var snapshot = (try? load()) ?? ActivitySnapshot()
            change(&snapshot)
            snapshot.completed = Array(snapshot.completed.prefix(ActivitySnapshot.maximumCompleted))
            snapshot.conflicts = Array(snapshot.conflicts.prefix(ActivitySnapshot.maximumConflicts))
            try Self.encoder.encode(snapshot).write(to: fileURL, options: .atomic)
            return snapshot
        }
        Self.postChange()
        return updated
    }

    // MARK: - Common changes

    public func recordHealth(_ health: ServerHealth, for serverID: UUID) throws {
        // Only a change of state is written, so a server answering every
        // request does not rewrite the file on every request.
        if let current = try? load().servers[serverID], current.state == health.state,
           current.message == health.message {
            return
        }
        try update { $0.servers[serverID] = health }
    }

    public func recordConflict(_ conflict: ConflictRecord) throws {
        try update { $0.conflicts.insert(conflict, at: 0) }
    }

    /// Drops everything about a server that was deleted or unmounted.
    public func forget(serverID: UUID) throws {
        try update { snapshot in
            snapshot.transfers.removeAll { $0.serverID == serverID }
            snapshot.completed.removeAll { $0.serverID == serverID }
            snapshot.conflicts.removeAll { $0.serverID == serverID }
            snapshot.servers[serverID] = nil
        }
    }

    private static func postChange() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center, CFNotificationName(changeNotification as CFString), nil, nil, true)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
