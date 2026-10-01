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
import HamasenCore
import Observation

/// What the extension reports it is doing: the files in flight, what just
/// finished, the conflicts it kept both sides of, and how each server last
/// answered it.
///
/// The extension posts a Darwin notification after each write; the file is
/// also re-read every few seconds, which covers a notification missed while
/// the app was busy and ages out transfers whose process went away.
@MainActor
@Observable
final class ActivityMonitor {
    /// A transfer that has not moved for this long belonged to an extension
    /// process that is gone, and is no longer shown.
    private static let staleAfter: TimeInterval = 120
    private static let pollInterval = Duration.seconds(3)

    private(set) var snapshot = ActivitySnapshot()
    /// Each transfer's speed now, and the clock it is judged by.
    private var rates = TransferRates()

    /// When the store was last read with something in flight, which is
    /// what speeds and staleness are judged against — a stalled transfer
    /// writes nothing, so without this its last speed would stay on screen.
    var lastRead: Date { rates.now }

    private var poll: Task<Void, Never>?
    private var isObserving = false
    /// Conflicts already seen, so each is announced once.
    private var seenConflicts: Set<UUID>?
    private var onNewConflicts: @MainActor ([ConflictRecord]) -> Void = { _ in }
    private var onChange: @MainActor () -> Void = {}

    var transfers: [TransferRecord] {
        let cutoff = lastRead.addingTimeInterval(-Self.staleAfter)
        return snapshot.transfers.filter { $0.updatedAt > cutoff }
    }

    /// Bytes per second now, or nil while the transfer is waiting or has
    /// not moved enough to say.
    func currentRate(of transfer: TransferRecord) -> Double? {
        rates.rate(of: transfer)
    }

    func secondsRemaining(of transfer: TransferRecord) -> TimeInterval? {
        rates.secondsRemaining(of: transfer)
    }

    var recentCompletions: [CompletedTransfer] { snapshot.completed }
    var recentConflicts: [ConflictRecord] { snapshot.conflicts }

    func transfers(for serverID: UUID) -> [TransferRecord] {
        transfers.filter { $0.serverID == serverID }
    }

    func health(for serverID: UUID) -> ServerHealth? {
        snapshot.servers[serverID]
    }

    /// Bytes per second across every transfer in flight.
    var combinedRate: Double {
        transfers.compactMap(currentRate(of:)).reduce(0, +)
    }

    func start(
        onNewConflicts: @escaping @MainActor ([ConflictRecord]) -> Void,
        onChange: @escaping @MainActor () -> Void
    ) {
        self.onNewConflicts = onNewConflicts
        self.onChange = onChange
        guard poll == nil else { return }
        observeDarwinNotification()
        reload()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                self?.reload()
            }
        }
    }

    func reload() {
        guard let store = try? ActivityStore(), let loaded = try? store.load() else { return }
        let changed = loaded != snapshot
        // The clock moves only while something shown can change with it: a
        // transfer going quiet or going stale. Moving it with nothing to
        // judge would redraw every view that lists transfers on every poll.
        if changed || !transfers.isEmpty {
            rates.update(with: loaded.transfers, at: Date())
        }
        if changed { snapshot = loaded }
        defer { if changed { onChange() } }

        let ids = Set(loaded.conflicts.map(\.id))
        if let seenConflicts {
            let new = loaded.conflicts.filter { !seenConflicts.contains($0.id) }
            if !new.isEmpty { onNewConflicts(new) }
            self.seenConflicts = seenConflicts.union(ids)
        } else {
            // The first read is history, not news.
            seenConflicts = ids
        }
    }

    /// Clears the conflict list once the person has looked at it.
    func clearConflicts() {
        _ = try? ActivityStore().update { $0.conflicts.removeAll() }
        reload()
    }

    /// Drops what the store holds about a connection that is gone.
    func forget(serverID: UUID) {
        _ = try? ActivityStore().forget(serverID: serverID)
        reload()
    }

    private func observeDarwinNotification() {
        guard !isObserving else { return }
        isObserving = true
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center, observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let monitor = Unmanaged<ActivityMonitor>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in monitor.reload() }
            },
            ActivityStore.changeNotification as CFString, nil, .deliverImmediately)
    }
}
