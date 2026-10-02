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

import Darwin
import Foundation
import SMBClient
import Testing
@testable import HamasenCore

@Suite("SMBFileService")
struct SMBFileServiceTests {
    /// A host that takes the connection and never says a word — a hung
    /// server, or a link that stopped carrying packets. SMBClient waits on
    /// it for good and does not stop when cancelled, so the timeout has to
    /// answer without waiting for the request to give up.
    @Test("伺服器接受連線卻不回應時，在時限內回報連線失敗", .timeLimit(.minutes(1)))
    func connectGivesUpOnASilentServer() async throws {
        let listener = try SilentListener()
        defer { listener.close() }
        let service = SMBFileService(
            config: ServerConfig(
                name: "測試伺服器", transferProtocol: .smb, host: "127.0.0.1", port: listener.port,
                username: "user", remotePath: "/share"),
            credentials: .password("password"),
            connectTimeoutSeconds: 1)

        let started = ContinuousClock.now
        do {
            try await service.connect()
            Issue.record("connected to a server that never answered")
        } catch RemoteFileServiceError.connectionFailed {
        }
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(await !service.isConnected)
    }

    // MARK: - Deadline

    /// SMBClient sends one request at a time, so a call can wait behind a
    /// transfer longer than the deadline while the link is doing fine.
    @Test("排在傳輸後面的請求，只要連線仍有進展就不逾時", .timeLimit(.minutes(1)))
    func queuedCallOutlastsTheDeadlineWhileTheSessionMoves() async throws {
        let liveness = Liveness()
        let abandoned = Flag()
        // The queued call waits longer than its own deadline in total, while
        // the longest silence is a fraction of it: wide enough apart that a
        // slow CI runner's scheduling stalls cannot pass for a dead link.
        async let transfer: Void = answering(within: 2, on: liveness, abandon: { abandoned.raise() }) {
            for _ in 0..<10 {
                try await Task.sleep(for: .milliseconds(250))
                liveness.touch()
            }
        }
        async let queued: Void = answering(within: 2, on: liveness, abandon: { abandoned.raise() }) {
            try await Task.sleep(for: .milliseconds(2_800))
        }
        _ = try await (transfer, queued)
        #expect(!abandoned.isRaised)
    }

    @Test("連線停住時，後來排入的請求不會延後時限")
    func callsQueuedOnAStalledSessionDoNotPostponeTheDeadline() {
        let liveness = Liveness()
        let start = ContinuousClock.now
        liveness.begin(allowing: .seconds(30), at: start)
        liveness.begin(allowing: .seconds(30), at: start + .seconds(20))
        #expect(liveness.timeLeft(at: start + .seconds(25)) == .seconds(5))
        #expect(liveness.timeLeft(at: start + .seconds(30)) == nil)
    }

    @Test("沒有請求的閒置時間不算進時限")
    func idleTimeIsNotSilence() {
        let liveness = Liveness()
        let start = ContinuousClock.now
        liveness.begin(allowing: .seconds(30), at: start)
        liveness.end(allowing: .seconds(30))
        liveness.begin(allowing: .seconds(30), at: start + .seconds(600))
        #expect(liveness.timeLeft(at: start + .seconds(601)) == .seconds(29))
    }

    /// The calls queued behind a listing wait on the same link it does, so
    /// they must not write the session off before the listing's own limit.
    @Test("排在列目錄後面的請求，沿用列目錄較長的時限")
    func theLongestAllowanceInFlightDecides() {
        let liveness = Liveness()
        let start = ContinuousClock.now
        liveness.begin(allowing: .seconds(120), at: start)
        liveness.begin(allowing: .seconds(30), at: start + .seconds(10))
        #expect(liveness.timeLeft(at: start + .seconds(60)) == .seconds(60))
        liveness.end(allowing: .seconds(120))
        #expect(liveness.timeLeft(at: start + .seconds(60)) == nil)
    }

    // MARK: - Replacing a file

    private static let destination = #"Docs\report.txt"#
    private static let upload = #"Docs\.hamasen-upload-aaaa1111-report.txt"#
    private static let backup = #"Docs\.hamasen-upload-bbbb2222-report.txt"#

    @Test("上傳取代既有檔案，不留下隱藏的暫存檔")
    func replacesAnExistingFile() async throws {
        let share = FakeShare([Self.destination: .file("old"), Self.upload: .file("new")])
        try await SMBFileService.replace(Self.destination, with: Self.upload, aside: Self.backup, on: share)
        #expect(await share.entries == [Self.destination: .file("new")])
    }

    /// Windows refuses to rename a file its virus scanner still holds open,
    /// as it often is right after being written.
    @Test("上傳無法移入原位時，舊檔案仍在原處")
    func failedReplaceKeepsTheOldFile() async throws {
        let share = FakeShare(
            [Self.destination: .file("old"), Self.upload: .file("new")],
            refusing: [(from: Self.upload, to: Self.destination)])
        await #expect(throws: ErrorResponse.self) {
            try await SMBFileService.replace(Self.destination, with: Self.upload, aside: Self.backup, on: share)
        }
        #expect(await share.entries == [Self.destination: .file("old")])
    }

    @Test("同名的是資料夾時不取代，資料夾放回原處")
    func doesNotReplaceAFolder() async throws {
        let share = FakeShare([Self.destination: .directory, Self.upload: .file("new")])
        let error = await #expect(throws: ErrorResponse.self) {
            try await SMBFileService.replace(Self.destination, with: Self.upload, aside: Self.backup, on: share)
        }
        #expect(error.map { NTStatus($0.header.status) == .objectNameCollision } == true)
        #expect(await share.entries == [Self.destination: .directory])
    }

    @Test("舊檔案也放不回去時，兩個版本都保留")
    func keepsBothVersionsWhenTheOldFileCannotGoBack() async throws {
        let share = FakeShare(
            [Self.destination: .file("old"), Self.upload: .file("new")],
            refusing: [(from: Self.upload, to: Self.destination), (from: Self.backup, to: Self.destination)])
        await #expect(throws: ErrorResponse.self) {
            try await SMBFileService.replace(Self.destination, with: Self.upload, aside: Self.backup, on: share)
        }
        #expect(await share.entries == [Self.upload: .file("new"), Self.backup: .file("old")])
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    var isRaised: Bool { lock.withLock { raised } }

    func raise() {
        lock.withLock { raised = true }
    }
}

/// A share in memory, answering as a server does: a rename onto a name in
/// use is refused, and so is any rename the test lists.
private actor FakeShare: SMBReplacing {
    enum Entry: Equatable {
        case file(String)
        case directory
    }

    private struct Move: Hashable {
        let from: String
        let to: String
    }

    private(set) var entries: [String: Entry]
    private let refusals: Set<Move>

    init(_ entries: [String: Entry], refusing refusals: [(from: String, to: String)] = []) {
        self.entries = entries
        self.refusals = Set(refusals.map { Move(from: $0.from, to: $0.to) })
    }

    func move(from: String, to: String) async throws {
        guard let entry = entries[from] else { throw status(.objectNameNotFound) }
        guard entries[to] == nil else { throw status(.objectNameCollision) }
        guard !refusals.contains(Move(from: from, to: to)) else { throw status(.sharingViolation) }
        entries[from] = nil
        entries[to] = entry
    }

    func existDirectory(path: String) async throws -> Bool {
        entries[path] == .directory
    }

    func deleteFile(path: String) async throws {
        guard entries[path] != nil else { throw status(.objectNameNotFound) }
        entries[path] = nil
    }
}

/// An SMB2 error response carrying `code`, the way SMBClient throws one.
private func status(_ code: ErrorCode) -> ErrorResponse {
    var message = Data(count: 72)
    withUnsafeBytes(of: code.rawValue.littleEndian) { message.replaceSubrange(8..<12, with: $0) }
    return ErrorResponse(data: message)
}

/// A listening socket nobody accepts from. The kernel completes the
/// handshake on its behalf, so a client connects, sends, and hears nothing.
private final class SilentListener {
    let port: Int
    private let descriptor: Int32

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EBADF) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 4) == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.EADDRINUSE)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        self.descriptor = descriptor
        port = Int(UInt16(bigEndian: address.sin_port))
    }

    func close() {
        Darwin.close(descriptor)
    }
}
