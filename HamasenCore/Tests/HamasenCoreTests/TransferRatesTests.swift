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
import Testing
@testable import HamasenCore

@Suite("TransferRates")
struct TransferRatesTests {
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)
    private static let megabyte: Int64 = 1_000_000

    private static func record(
        id: UUID = UUID(), bytes: Int64, total: Int64 = 100 * megabyte, at seconds: TimeInterval,
        startedAt: TimeInterval = 0
    ) -> TransferRecord {
        TransferRecord(
            id: id, serverID: UUID(), path: "/movies/a.mov", direction: .download,
            bytesTransferred: bytes, totalBytes: total,
            startedAt: start.addingTimeInterval(startedAt), updatedAt: start.addingTimeInterval(seconds))
    }

    private static func read(_ rates: inout TransferRates, _ transfers: [TransferRecord], at seconds: TimeInterval) {
        rates.update(with: transfers, at: start.addingTimeInterval(seconds))
    }

    /// The first time a transfer is seen there is only its average to go on,
    /// and the first reading after that is one short sample of it: it moves
    /// the speed from the average, it does not replace it.
    @Test
    func firstReadingStartsFromTheAverage() throws {
        let id = UUID()
        var rates = TransferRates()
        Self.read(&rates, [Self.record(id: id, bytes: 2 * Self.megabyte, at: 2)], at: 2)
        #expect(rates.rate(of: Self.record(id: id, bytes: 2 * Self.megabyte, at: 2)) == 1_000_000)

        // Half a second at 2 MB/s.
        let next = Self.record(id: id, bytes: 3 * Self.megabyte, at: 2.5)
        Self.read(&rates, [next], at: 2.5)
        let rate = try #require(rates.rate(of: next))
        #expect(rate > 1_000_000)
        #expect(rate < 1_500_000)
    }

    @Test
    func justBegunHasNoSpeed() {
        let begun = Self.record(bytes: 0, at: 0)
        var rates = TransferRates()
        Self.read(&rates, [begun], at: 0)
        #expect(rates.rate(of: begun) == nil)
        #expect(rates.secondsRemaining(of: begun) == nil)
    }

    /// A reading counts for as long as it covers: one SMB chunk reported
    /// after eight seconds says far more than one tenth of a second does.
    @Test
    func readingsCountForTheTimeTheyCover() throws {
        let id = UUID()
        var rates = TransferRates()
        Self.read(&rates, [Self.record(id: id, bytes: 10 * Self.megabyte, at: 10)], at: 10)

        // A tenth of a second at 5 MB/s barely moves 1 MB/s.
        let brief = Self.record(id: id, bytes: 10 * Self.megabyte + 500_000, at: 10.1)
        Self.read(&rates, [brief], at: 10.1)
        #expect(try #require(rates.rate(of: brief)) < 1_400_000)

        // Eight seconds at 4 MB/s is what the transfer is doing now.
        let long = Self.record(id: id, bytes: brief.bytesTransferred + 32 * Self.megabyte, at: 18.1)
        Self.read(&rates, [long], at: 18.1)
        #expect(try #require(rates.rate(of: long)) > 3_900_000)
    }

    /// The record is read whenever anything in it changes; a transfer that
    /// did not report in between keeps the speed it had.
    @Test
    func readingWithoutANewReportKeepsTheSpeed() throws {
        let id = UUID()
        var rates = TransferRates()
        Self.read(&rates, [Self.record(id: id, bytes: 2 * Self.megabyte, at: 2)], at: 2)
        let moved = Self.record(id: id, bytes: 4 * Self.megabyte, at: 3)
        Self.read(&rates, [moved], at: 3)
        let before = try #require(rates.rate(of: moved))

        Self.read(&rates, [moved], at: 3.5)
        #expect(rates.rate(of: moved) == before)
    }

    /// A retry rescales the same progress back to zero. That is the count
    /// starting over, not the transfer stopping dead.
    @Test
    func startingOverKeepsTheSpeed() throws {
        let id = UUID()
        var rates = TransferRates()
        Self.read(&rates, [Self.record(id: id, bytes: 8 * Self.megabyte, at: 8)], at: 8)
        let before = try #require(rates.rate(of: Self.record(id: id, bytes: 8 * Self.megabyte, at: 8)))

        let retried = Self.record(id: id, bytes: 0, at: 9)
        Self.read(&rates, [retried], at: 9)
        #expect(rates.rate(of: retried) == before)

        // And it counts from zero again: 2 MB/s for a second.
        let moving = Self.record(id: id, bytes: 2 * Self.megabyte, at: 10)
        Self.read(&rates, [moving], at: 10)
        let rate = try #require(rates.rate(of: moving))
        #expect(rate > before)
        #expect(rate < 2_000_000)
    }

    /// A restarted extension begins the same file again under a new record.
    /// It is a transfer of its own, with nothing carried over from the old.
    @Test
    func newRecordAfterRestartStartsAfresh() throws {
        let old = UUID()
        var rates = TransferRates()
        Self.read(&rates, [Self.record(id: old, bytes: 50 * Self.megabyte, at: 5)], at: 5)
        let fast = Self.record(id: old, bytes: 90 * Self.megabyte, at: 6)
        Self.read(&rates, [fast], at: 6)
        #expect(try #require(rates.rate(of: fast)) > 10_000_000)

        let again = Self.record(bytes: 1 * Self.megabyte, at: 12, startedAt: 10)
        Self.read(&rates, [again], at: 12)
        #expect(rates.rate(of: again) == 500_000)
        #expect(rates.rate(of: fast) == nil)
    }

    /// Quiet for longer than usual is waiting. What is usual depends on the
    /// transfer: a few seconds for one reporting twice a second, a good deal
    /// more for one reporting once per large chunk.
    @Test
    func idleIsJudgedByEachTransfersOwnPace() {
        let chunked = UUID()
        let streaming = UUID()
        var rates = TransferRates()
        Self.read(&rates, [
            Self.record(id: chunked, bytes: 8 * Self.megabyte, at: 8),
            Self.record(id: streaming, bytes: 1 * Self.megabyte, at: 8),
        ], at: 8)
        Self.read(&rates, [
            Self.record(id: chunked, bytes: 8 * Self.megabyte, at: 8),
            Self.record(id: streaming, bytes: 1 * Self.megabyte + 50_000, at: 15.5),
        ], at: 15.5)
        let chunk = Self.record(id: chunked, bytes: 16 * Self.megabyte, at: 16)
        let stream = Self.record(id: streaming, bytes: 1 * Self.megabyte + 100_000, at: 16)
        Self.read(&rates, [chunk, stream], at: 16)
        #expect(rates.rate(of: chunk) != nil)
        #expect(rates.rate(of: stream) != nil)

        // Ten seconds without a report: well within the chunked transfer's
        // pace, far beyond the streaming one's.
        Self.read(&rates, [chunk, stream], at: 26)
        #expect(rates.rate(of: chunk) != nil)
        #expect(rates.rate(of: stream) == nil)

        // Past twice its own pace, the chunked one is waiting too.
        Self.read(&rates, [chunk, stream], at: 33)
        #expect(rates.rate(of: chunk) == nil)
        #expect(rates.secondsRemaining(of: chunk) == nil)
    }

    /// A stall followed by one report is not the transfer's new pace: taken
    /// as one, the next stall would keep a speed made almost entirely of the
    /// stall on screen for twice its length.
    @Test
    func aStallIsNotTakenForThePace() {
        let id = UUID()
        var rates = TransferRates()
        for (index, seconds) in [0.0, 0.5, 1.0].enumerated() {
            Self.read(&rates, [Self.record(id: id, bytes: Int64(index + 1) * Self.megabyte, at: seconds)], at: seconds)
        }
        let resumed = Self.record(id: id, bytes: 4 * Self.megabyte, at: 31)
        Self.read(&rates, [resumed], at: 31)
        #expect(rates.rate(of: resumed) != nil)

        Self.read(&rates, [resumed], at: 37)
        #expect(rates.rate(of: resumed) == nil)
    }

    /// One that really does report slowly is recognised within a few
    /// reports, and then not taken for idle between them.
    @Test
    func aSlowPaceIsLearned() {
        let id = UUID()
        var rates = TransferRates()
        var latest = Self.record(id: id, bytes: 0, at: 0)
        Self.read(&rates, [latest], at: 0)
        for report in 1...8 {
            latest = Self.record(id: id, bytes: Int64(report) * Self.megabyte, at: Double(report) * 20)
            Self.read(&rates, [latest], at: Double(report) * 20)
        }
        Self.read(&rates, [latest], at: 8 * 20 + 15)
        #expect(rates.rate(of: latest) != nil)
    }

    @Test
    func remainingTimeOnlyWhenItMeansSomething() {
        let transfer = Self.record(bytes: 0, total: 10_000 * Self.megabyte, at: 0)
        #expect(transfer.secondsRemaining(at: 1_000_000) == 10_000)
        #expect(transfer.secondsRemaining(at: nil) == nil)
        #expect(transfer.secondsRemaining(at: 0) == nil)
        // Ten gigabytes at a trickle is not an estimate anyone can use.
        #expect(transfer.secondsRemaining(at: 10) == nil)
        // 99 hours is about 28 KB/s for ten gigabytes.
        #expect(transfer.secondsRemaining(at: 29_000) != nil)
        #expect(transfer.secondsRemaining(at: 28_000) == nil)

        let done = Self.record(bytes: 5 * Self.megabyte, total: 5 * Self.megabyte, at: 5)
        #expect(done.secondsRemaining(at: 1_000_000) == nil)
    }
}
