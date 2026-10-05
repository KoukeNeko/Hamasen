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

/// What a bad network does to each client: slow, fragmented, cut off, or
/// gone. Through toxiproxy, so one at a time — a toxic is on a proxy every
/// client of that server shares.
@Suite("Network faults", .enabled(if: E2E.isAvailable), .serialized)
struct FaultTests {
    static let lanes = Lane.allCases.filter { $0.proxy != nil }

    init() async throws {
        try await Toxiproxy.reset()
    }

    private static func workspace(_ lane: Lane) async throws -> (Mount, String) {
        let mount = Mount(LaneClients(lane: lane))
        let folder = "/" + E2E.uniqueName("faults")
        try await mount.write { try await $0.createDirectory(at: folder) }
        return (mount, folder)
    }

    private static func cleanUp(_ mount: Mount, _ folder: String) async {
        try? await Toxiproxy.reset()
        _ = try? await mount.write { try await $0.deleteDirectory(at: folder) }
        await mount.close()
    }

    /// Uploads, reads back whole and in part, lists and renames, checking
    /// every byte.
    private static func roundTrip(_ mount: Mount, in folder: String, size: Int, seed: UInt64) async throws {
        let data = Fixtures.bytes(size, seed: seed)
        let path = RemotePath.join(folder, "trip-\(seed).bin")
        let hash = try await mount.write { try await Fixtures.upload(data, to: path, with: $0) }
        #expect(try await mount.read { try await Fixtures.downloadHash(path, with: $0) } == hash)
        let offset = size / 3
        let slice = try await mount.read { try await $0.downloadRange(at: path, offset: Int64(offset), length: 4_096) }
        #expect(slice == data.subdata(in: offset..<min(size, offset + 4_096)))
        let renamed = RemotePath.join(folder, "trip-\(seed)-renamed.bin")
        try await mount.write { try await $0.moveItem(from: path, to: renamed) }
        let names = try await mount.read { try await $0.listDirectory(at: folder) }.map(\.name)
        #expect(names.contains("trip-\(seed)-renamed.bin"))
        #expect(!names.contains("trip-\(seed).bin"))
    }

    @Test("延遲高的網路，內容仍一致", arguments: lanes)
    func survivesLatency(lane: Lane) async throws {
        let (mount, folder) = try await Self.workspace(lane)
        try await Toxiproxy.with(.latency(milliseconds: 250), on: lane.proxy!) {
            try await E2E.withDeadline(180, "\(lane) under latency") {
                try await Self.roundTrip(mount, in: folder, size: 300_000, seed: 1)
            }
        }
        await Self.cleanUp(mount, folder)
    }

    @Test("封包被切碎時，內容仍一致", arguments: lanes)
    func survivesFragmentation(lane: Lane) async throws {
        let (mount, folder) = try await Self.workspace(lane)
        try await Toxiproxy.with(.slicer(averageBytes: 64), on: lane.proxy!, stream: "downstream") {
            try await Toxiproxy.with(.slicer(averageBytes: 64), on: lane.proxy!, stream: "upstream") {
                try await E2E.withDeadline(180, "\(lane) with fragmented packets") {
                    try await Self.roundTrip(mount, in: folder, size: 200_000, seed: 2)
                }
            }
        }
        await Self.cleanUp(mount, folder)
    }

    @Test("頻寬受限時，傳輸仍完成", arguments: lanes)
    func survivesLowBandwidth(lane: Lane) async throws {
        let (mount, folder) = try await Self.workspace(lane)
        try await Toxiproxy.with(.bandwidth(kilobytesPerSecond: 256), on: lane.proxy!, stream: "upstream") {
            try await Toxiproxy.with(.bandwidth(kilobytesPerSecond: 256), on: lane.proxy!) {
                try await E2E.withDeadline(180, "\(lane) at 256 KB/s") {
                    try await Self.roundTrip(mount, in: folder, size: 1_500_000, seed: 3)
                }
            }
        }
        await Self.cleanUp(mount, folder)
    }

    /// The 30-second limit the app promises is the client's, so a server
    /// that never answers must fail within it rather than leave the person
    /// watching a spinner.
    @Test("伺服器無法連線時，在時限內回報失敗", arguments: lanes)
    func failsFastWhenUnreachable(lane: Lane) async throws {
        try await Toxiproxy.setEnabled(false, proxy: lane.proxy!)
        let clients = LaneClients(lane: lane, connectTimeoutSeconds: 5)
        let started = Date()
        do {
            _ = try await E2E.withDeadline(30, "\(lane) connecting to nothing") { try await clients.connected() }
            Issue.record("\(lane) connected to a server that is not there")
        } catch let error as RemoteFileServiceError {
            #expect(Mount.isConnectionFailure(error), "\(lane): \(error)")
        } catch {
            Issue.record("\(lane): \(error)")
        }
        #expect(Date().timeIntervalSince(started) < 30)
        try await Toxiproxy.setEnabled(true, proxy: lane.proxy!)
        _ = try await clients.connected()
    }

    /// A stall — packets dropped, nothing refused — is the fault a timeout
    /// alone catches.
    @Test("連線停住不動時，操作在時限內失敗，之後恢復", arguments: lanes)
    func recoversFromStall(lane: Lane) async throws {
        let (mount, folder) = try await Self.workspace(lane)
        let path = RemotePath.join(folder, "stalled.bin")
        _ = try await mount.write { try await Fixtures.upload(Fixtures.bytes(50_000, seed: 4), to: path, with: $0) }

        let stalled = try await Toxiproxy.with(.timeout(milliseconds: 0), on: lane.proxy!) {
            try await E2E.withDeadline(150, "\(lane) listing over a stalled link") {
                do {
                    _ = try await mount.read { try await $0.listDirectory(at: folder) }
                    return false
                } catch {
                    return true
                }
            }
        }
        #expect(stalled, "\(lane) answered over a link that carries nothing")

        let names = try await E2E.withDeadline(60, "\(lane) after the stall") {
            try await mount.read { try await $0.listDirectory(at: folder) }.map(\.name)
        }
        #expect(names == ["stalled.bin"])
        await Self.cleanUp(mount, folder)
    }

    /// An upload cut off halfway must leave the file as it was or as it was
    /// going to be — never half of the new one under the real name — and
    /// must not leave behind anything that stops its folder being deleted.
    @Test("上傳中途斷線，檔案不會只剩一半，資料夾仍可刪除", arguments: lanes)
    func survivesInterruptedUpload(lane: Lane) async throws {
        let (mount, folder) = try await Self.workspace(lane)
        let inner = RemotePath.join(folder, "inner")
        try await mount.write { try await $0.createDirectory(at: inner) }
        let path = RemotePath.join(inner, "document.bin")
        let original = try await mount.write {
            try await Fixtures.upload(Fixtures.bytes(400_000, seed: 5), to: path, with: $0)
        }
        let replacement = Fixtures.bytes(3_000_000, seed: 6)

        let interrupted = try await Toxiproxy.cutting(lane.proxy!, after: 2, slowedBy: lane.uploadSlowing) {
            _ = try await E2E.withDeadline(120, "\(lane) upload cut off") {
                try await mount.write { try await Fixtures.upload(replacement, to: path, with: $0) }
            }
        }
        #expect(interrupted, "\(lane) finished uploading 3 MB before the link was cut")

        let after = try await mount.read { try await Fixtures.downloadHash(path, with: $0) }
        #expect(after == original || after == Fixtures.sha256(replacement), "\(lane) left a partial file")
        let names = try await mount.read { try await $0.listDirectory(at: inner) }.map(\.name)
        #expect(names == ["document.bin"], "\(lane) lists \(names)")

        do {
            try await mount.write { try await $0.deleteDirectory(at: inner) }
        } catch {
            Issue.record("\(lane) cannot delete a folder an upload was cut off in: \(error)")
        }
        await Self.cleanUp(mount, folder)
    }

    @Test("雲端服務限流時，操作等候後完成", arguments: lanes.filter { $0.oauthProvider != nil })
    func waitsOutThrottling(lane: Lane) async throws {
        let (mount, folder) = try await Self.workspace(lane)
        try await CloudMock.throttle(lane.oauthProvider!, count: 3)
        try await E2E.withDeadline(120, "\(lane) while throttled") {
            try await Self.roundTrip(mount, in: folder, size: 10_000, seed: 7)
        }
        await Self.cleanUp(mount, folder)
    }

    /// A restart closes every session the server had. The next operation
    /// finds its session dead and has to come back on a new one.
    @Test("伺服器重新啟動後，下一個操作自動重新連線", arguments: lanes.filter { $0.oauthProvider == nil })
    func reconnectsAfterRestart(lane: Lane) async throws {
        let (mount, folder) = try await Self.workspace(lane)
        let path = RemotePath.join(folder, "before-restart.bin")
        let hash = try await mount.write { try await Fixtures.upload(Fixtures.bytes(20_000, seed: 8), to: path, with: $0) }

        try await ServerControl.restart(lane.service)

        let after = try await E2E.withDeadline(90, "\(lane) after a restart") {
            try await mount.read { try await Fixtures.downloadHash(path, with: $0) }
        }
        #expect(after == hash)
        await Self.cleanUp(mount, folder)
    }
}
