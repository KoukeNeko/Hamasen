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

import FileProvider
import Foundation
import HamasenCore

/// Writes what the extension is doing to the activity store for the app.
///
/// Progress moves on every chunk, and the app only needs to see it a few
/// times a second, so byte counts are held here and written at most twice a
/// second; a transfer starting or ending, a conflict, or a server changing
/// state is written straight away.
actor ActivityRecorder {
    static let shared = ActivityRecorder()

    /// A transfer's progress as it reaches the recorder. Sent through one
    /// stream so they arrive in the order they happened: separate tasks
    /// could deliver a transfer's end before its start, leaving a record
    /// that never finishes.
    enum TransferEvent: Sendable {
        case begin(TransferRecord)
        case update(UUID, bytesTransferred: Int64, totalBytes: Int64)
        case finish(UUID, failure: String?)
    }

    private static let flushInterval = Duration.milliseconds(500)
    private static let log = HamasenLog(category: "activity")

    nonisolated let events: AsyncStream<TransferEvent>.Continuation
    private let store = try? ActivityStore()
    private var transfers: [UUID: TransferRecord] = [:]
    private var pendingCompletions: [CompletedTransfer] = []
    private var knownHealth: [UUID: ServerHealth] = [:]
    private var flush: Task<Void, Never>?

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: TransferEvent.self)
        events = continuation
        Task { [weak self] in
            for await event in stream {
                await self?.handle(event)
            }
        }
    }

    private func handle(_ event: TransferEvent) {
        switch event {
        case .begin(let record): begin(record)
        case .update(let id, let bytes, let total): update(id, bytesTransferred: bytes, totalBytes: total)
        case .finish(let id, let failure): finish(id, failure: failure)
        }
    }

    /// Whatever the last process left in flight did not survive it.
    func clearTransfers() {
        transfers.removeAll()
        write { $0.transfers.removeAll() }
    }

    func begin(_ record: TransferRecord) {
        transfers[record.id] = record
        writeSoon(immediately: true)
    }

    func update(_ id: UUID, bytesTransferred: Int64, totalBytes: Int64) {
        guard var record = transfers[id] else { return }
        record.bytesTransferred = bytesTransferred
        record.totalBytes = max(totalBytes, bytesTransferred)
        record.updatedAt = Date()
        transfers[id] = record
        writeSoon(immediately: false)
    }

    func finish(_ id: UUID, failure: String?) {
        guard let record = transfers.removeValue(forKey: id) else { return }
        pendingCompletions.insert(
            CompletedTransfer(
                id: record.id, serverID: record.serverID, path: record.path, direction: record.direction,
                totalBytes: record.totalBytes, failure: failure),
            at: 0)
        writeSoon(immediately: true)
    }

    func recordHealth(_ health: ServerHealth, for serverID: UUID) {
        // Every successful operation reports the server reachable; only a
        // change is worth a trip to the file.
        if let known = knownHealth[serverID], known.state == health.state, known.message == health.message {
            return
        }
        knownHealth[serverID] = health
        do {
            try store?.recordHealth(health, for: serverID)
        } catch {
            Self.log.error("Could not record how \(serverID) answered: \(error.localizedDescription)")
        }
    }

    func recordConflict(_ conflict: ConflictRecord) {
        do {
            try store?.recordConflict(conflict)
        } catch {
            Self.log.error("Could not record the conflict on \(conflict.path): \(error.localizedDescription)")
        }
    }

    private func writeSoon(immediately: Bool) {
        if immediately {
            flush?.cancel()
            flush = nil
            writeTransfers()
            return
        }
        guard flush == nil else { return }
        flush = Task { [weak self] in
            try? await Task.sleep(for: Self.flushInterval)
            guard !Task.isCancelled else { return }
            await self?.flushed()
        }
    }

    private func flushed() {
        flush = nil
        writeTransfers()
    }

    private func writeTransfers() {
        let current = transfers.values.sorted { $0.startedAt < $1.startedAt }
        let completions = pendingCompletions
        pendingCompletions.removeAll()
        write { snapshot in
            snapshot.transfers = current
            snapshot.completed.insert(contentsOf: completions, at: 0)
        }
    }

    private func write(_ change: (inout ActivitySnapshot) -> Void) {
        do {
            try store?.update(change)
        } catch {
            Self.log.error("Could not write the activity record: \(error.localizedDescription)")
        }
    }
}

/// One operation's transfer, if it turns out to be one.
///
/// Every operation runs on a `Progress`, and only transfers rescale it to
/// bytes (`beginTransfer`), so the progress itself says when a transfer
/// starts and how far it has got. Watching it keeps the recording out of
/// every place a transfer is started.
final class TransferWatch: @unchecked Sendable {
    private let serverID: UUID
    private let path: String
    private let lock = NSLock()
    private var recordID: UUID?
    private var isFinished = false
    private var observation: NSKeyValueObservation?

    init(progress: Progress, serverID: UUID, path: String) {
        self.serverID = serverID
        self.path = path
        observation = progress.observe(\.completedUnitCount, options: [.initial, .new]) { [weak self] progress, _ in
            self?.observe(progress)
        }
    }

    private func observe(_ progress: Progress) {
        let direction: TransferDirection
        // A move between servers counts every byte twice, down and then up
        // (`moveAcrossServers`), so the system sees both passes advance; the
        // record is of the file, once.
        let passes: Int64
        switch progress.fileOperationKind {
        case .downloading?: (direction, passes) = (.download, 1)
        case .uploading?: (direction, passes) = (.upload, 1)
        case .copying?: (direction, passes) = (.move, 2)
        default: return
        }
        let total = progress.totalUnitCount / passes
        let completed = progress.completedUnitCount / passes
        let events = ActivityRecorder.shared.events
        // Yielded under the lock so a transfer's first event is always its
        // start, whichever thread the progress reports on.
        lock.withLock {
            guard !isFinished else { return }
            if let recordID {
                events.yield(.update(recordID, bytesTransferred: completed, totalBytes: total))
                return
            }
            let created = UUID()
            recordID = created
            events.yield(.begin(TransferRecord(
                id: created, serverID: serverID, path: path, direction: direction,
                bytesTransferred: completed, totalBytes: total)))
        }
    }

    /// Ends the record, if a transfer ever began. Called once, as the
    /// operation answers.
    func finish(failure: String?) {
        observation?.invalidate()
        lock.withLock {
            observation = nil
            isFinished = true
            guard let recordID else { return }
            ActivityRecorder.shared.events.yield(.finish(recordID, failure: failure))
        }
    }
}
