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

/// How fast each file in flight is moving now, from the activity record as
/// it is read again and again.
///
/// The average since a transfer started (`TransferRecord.bytesPerSecond`)
/// lags far behind one whose speed changes, so each read is compared with
/// the one before it. Reports arrive as often as a protocol hands over a
/// chunk — several a second for most, once per large request on a slow
/// link — so a reading counts for as long a time as it covers, not once per
/// report.
public struct TransferRates: Sendable {
    /// A transfer not reported on for this long — or for twice its own last
    /// gap between reports, when that is longer — is waiting rather than
    /// moving, and has no speed.
    static let idleAfter: TimeInterval = 5
    /// How quickly the speed follows a change: a reading that covers this
    /// long moves it about two-thirds of the way.
    static let smoothingTime: TimeInterval = 1.5

    private struct Sample: Sendable {
        var bytes: Int64
        var at: Date
        /// The time between the transfer's last two reports.
        var interval: TimeInterval?
        var rate: Double?
    }

    private var samples: [UUID: Sample] = [:]
    /// When the record was last read. A stalled transfer writes nothing, so
    /// its idleness can only be judged against the reader's clock.
    public private(set) var now: Date

    public init(now: Date = Date()) {
        self.now = now
    }

    /// Takes in the transfers as the record holds them at `now`. Transfers
    /// no longer in it are forgotten.
    public mutating func update(with transfers: [TransferRecord], at now: Date) {
        self.now = now
        var next: [UUID: Sample] = [:]
        for transfer in transfers {
            let bytes = transfer.bytesTransferred
            guard let previous = samples[transfer.id] else {
                // Seen for the first time — just begun, or already running
                // when the app started, or begun again under a new record by
                // a restarted extension. Its own average is the best guess
                // until a second report says more.
                next[transfer.id] = Sample(bytes: bytes, at: transfer.updatedAt, rate: transfer.bytesPerSecond)
                continue
            }
            if bytes < previous.bytes {
                // Started over: a retry rescales the same progress back to
                // zero. The connection's speed is still the best guess; only
                // the count starts again.
                next[transfer.id] = Sample(
                    bytes: bytes, at: transfer.updatedAt, interval: previous.interval, rate: previous.rate)
                continue
            }
            let elapsed = transfer.updatedAt.timeIntervalSince(previous.at)
            guard elapsed > 0 else {
                // Read again before its next report: something else in the
                // record changed, or time went by.
                next[transfer.id] = previous
                continue
            }
            let reading = Double(bytes - previous.bytes) / elapsed
            let weight = 1 - exp(-elapsed / Self.smoothingTime)
            let rate = (previous.rate ?? transfer.bytesPerSecond).map { $0 + weight * (reading - $0) } ?? reading
            // A gap far longer than the usual one is more likely a stall than
            // a new pace, and taken as the pace it would keep the next stall
            // from reading as one. Growing at most twofold per report, the
            // pace of a transfer that really reports this slowly is still
            // learned within a few reports.
            let interval = previous.interval.map { min(elapsed, 2 * $0) } ?? elapsed
            next[transfer.id] = Sample(bytes: bytes, at: transfer.updatedAt, interval: interval, rate: rate)
        }
        samples = next
    }

    /// Bytes per second now, or nil while the transfer is waiting or has
    /// not moved enough to say.
    public func rate(of transfer: TransferRecord) -> Double? {
        guard let sample = samples[transfer.id] else { return nil }
        let quiet = now.timeIntervalSince(transfer.updatedAt)
        guard quiet <= max(Self.idleAfter, 2 * (sample.interval ?? 0)) else { return nil }
        return sample.rate
    }

    public func secondsRemaining(of transfer: TransferRecord) -> TimeInterval? {
        transfer.secondsRemaining(at: rate(of: transfer))
    }
}
