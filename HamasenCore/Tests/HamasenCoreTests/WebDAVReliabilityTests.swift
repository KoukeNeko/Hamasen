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

/// Progress, versioning, cache freshness and error classification, against
/// the in-process server.
@Suite("WebDAV reliability")
struct WebDAVReliabilityTests {
    private static func makeService(port: Int) -> WebDAVFileService {
        WebDAVFileService(
            config: ServerConfig(
                name: "測試 WebDAV",
                transferProtocol: .webdav,
                host: "127.0.0.1",
                port: port,
                username: TestWebDAVServer.username,
                remotePath: RemotePath.root
            ),
            credentials: .password(TestWebDAVServer.password)
        )
    }

    private static func withService(
        behaviour: TestWebDAVServer.Behaviour = .wellBehaved,
        _ work: (WebDAVFileService, TestWebDAVServer) async throws -> Void
    ) async throws {
        let server = try await TestWebDAVServer.start(behaviour: behaviour)
        let service = makeService(port: server.port)
        do {
            try await service.connect()
            try await work(service, server)
        } catch {
            try? await service.disconnect()
            try? await server.stop()
            throw error
        }
        try await service.disconnect()
        try await server.stop()
    }

    /// Thread-safe recorder for the running totals a transfer reports.
    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var totals: [Int64] = []

        func record(_ total: Int64) {
            lock.lock()
            defer { lock.unlock() }
            totals.append(total)
        }

        var reported: [Int64] {
            lock.lock()
            defer { lock.unlock() }
            return totals
        }
    }

    private func temporaryFile(_ contents: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("webdav-reliability-\(UUID().uuidString)")
        try contents.write(to: url)
        return url
    }

    // MARK: - Progress

    @Test("上傳與下載會隨著位元組移動回報進度")
    func reportsProgressWhileTransferring() async throws {
        try await Self.withService { service, server in
            let payload = Data((0..<6_000_000).map { UInt8($0 % 251) })
            let source = try temporaryFile(payload)
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("webdav-download-\(UUID().uuidString)")
            defer {
                try? FileManager.default.removeItem(at: source)
                try? FileManager.default.removeItem(at: destination)
            }

            let uploaded = ProgressLog()
            try await service.uploadFile(from: source, to: "/big.bin", progress: { uploaded.record($0) })
            #expect(uploaded.reported.last == Int64(payload.count))
            #expect(!uploaded.reported.isEmpty)
            #expect(uploaded.reported == uploaded.reported.sorted())

            let downloaded = ProgressLog()
            try await service.downloadFile(at: "/big.bin", to: destination, progress: { downloaded.record($0) })
            #expect(downloaded.reported.last == Int64(payload.count))
            #expect(downloaded.reported.count > 1)
            #expect(try Data(contentsOf: destination) == payload)
            _ = server
        }
    }

    // MARK: - Content tag

    @Test("列表與單項查詢對同一檔案給出相同的 contentTag")
    func listingAndLookupAgreeOnTheContentTag() async throws {
        try await Self.withService { service, server in
            try Data("tagged".utf8).write(to: server.rootDirectory.appendingPathComponent("a.txt"))

            let listed = try #require(try await service.listDirectory(at: "/").first { $0.name == "a.txt" })
            let looked = try await service.itemInfo(at: "/a.txt")

            let tag = try #require(listed.contentTag)
            #expect(!tag.contains("\""))
            #expect(looked.contentTag == tag)
            #expect(looked.contentVersionToken == listed.contentVersionToken)
        }
    }

    @Test("伺服器不回報 ETag 時 contentTag 為空")
    func leavesTheContentTagEmptyWithoutAnETag() async throws {
        try await Self.withService(behaviour: .init(omitsETag: true)) { service, server in
            try Data("x".utf8).write(to: server.rootDirectory.appendingPathComponent("a.txt"))
            #expect(try await service.itemInfo(at: "/a.txt").contentTag == nil)
        }
    }

    // MARK: - Range cache freshness

    @Test("伺服器上的檔案被修改後，不會再從舊的整檔快取切出區間")
    func discardsTheCachedBodyWhenTheETagChanges() async throws {
        try await Self.withService(behaviour: .init(ignoresRange: true)) { service, server in
            let file = server.rootDirectory.appendingPathComponent("edit.bin")
            try Data(repeating: 0x41, count: 30_000).write(to: file)

            let first = try await service.downloadRange(at: "/edit.bin", offset: 0, length: 10)
            #expect(first == Data(repeating: 0x41, count: 10))

            // Same size, so only the validator can tell the copy is stale.
            try Data(repeating: 0x42, count: 30_000).write(to: file)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: file.path)

            let second = try await service.downloadRange(at: "/edit.bin", offset: 10, length: 10)
            #expect(second == Data(repeating: 0x42, count: 10))
            #expect(server.requestCount(method: "GET") == 2)
        }
    }

    @Test("沒有 ETag 時以修改時間與大小判斷快取是否過期")
    func discardsTheCachedBodyWhenLastModifiedChanges() async throws {
        try await Self.withService(behaviour: .init(ignoresRange: true, omitsETag: true)) { service, server in
            let file = server.rootDirectory.appendingPathComponent("edit.bin")
            try Data(repeating: 0x41, count: 30_000).write(to: file)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: file.path)

            _ = try await service.downloadRange(at: "/edit.bin", offset: 0, length: 10)
            // Unchanged: the retained copy still serves the next chunk.
            _ = try await service.downloadRange(at: "/edit.bin", offset: 10, length: 10)
            #expect(server.requestCount(method: "GET") == 1)

            try Data(repeating: 0x42, count: 30_000).write(to: file)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_700_000_100)], ofItemAtPath: file.path)

            let chunk = try await service.downloadRange(at: "/edit.bin", offset: 20, length: 10)
            #expect(chunk == Data(repeating: 0x42, count: 10))
            #expect(server.requestCount(method: "GET") == 2)
        }
    }

    @Test("檔案被刪除後區間讀取回報找不到，而不是回傳快取內容")
    func doesNotServeACachedBodyForADeletedFile() async throws {
        try await Self.withService(behaviour: .init(ignoresRange: true)) { service, server in
            let file = server.rootDirectory.appendingPathComponent("gone.bin")
            try Data(repeating: 0x41, count: 1_000).write(to: file)
            _ = try await service.downloadRange(at: "/gone.bin", offset: 0, length: 10)
            try FileManager.default.removeItem(at: file)

            await #expect(throws: RemoteFileServiceError.itemNotFound(path: "/gone.bin")) {
                _ = try await service.downloadRange(at: "/gone.bin", offset: 10, length: 10)
            }
        }
    }

    // MARK: - Error classification

    @Test("403 是權限錯誤")
    func forbiddenIsPermissionDenied() async throws {
        try await Self.withService(behaviour: .init(forbidsWrites: true)) { service, server in
            let source = try temporaryFile(Data("x".utf8))
            defer { try? FileManager.default.removeItem(at: source) }
            do {
                try await service.uploadFile(from: source, to: "/nope.txt")
                Issue.record("expected the upload to be refused")
            } catch RemoteFileServiceError.permissionDenied(_, let path) {
                #expect(path == "/nope.txt")
            }
            _ = server
        }
    }

    @Test("MOVE 遇到既有目的地（412）回報已存在")
    func moveOntoAnExistingNameIsAlreadyExists() async throws {
        try await Self.withService { service, server in
            try Data("a".utf8).write(to: server.rootDirectory.appendingPathComponent("a.txt"))
            try Data("b".utf8).write(to: server.rootDirectory.appendingPathComponent("b.txt"))
            await #expect(throws: RemoteFileServiceError.alreadyExists(path: "/b.txt")) {
                try await service.moveItem(from: "/a.txt", to: "/b.txt")
            }
        }
    }

    @Test("找不到的項目回報 itemNotFound")
    func missingItemIsNotFound() async throws {
        try await Self.withService { service, _ in
            await #expect(throws: RemoteFileServiceError.itemNotFound(path: "/missing.txt")) {
                try await service.deleteFile(at: "/missing.txt")
            }
            await #expect(throws: RemoteFileServiceError.itemNotFound(path: "/missing.txt")) {
                _ = try await service.itemInfo(at: "/missing.txt")
            }
        }
    }

    @Test("DELETE 的 207 內含 403 成員時是權限錯誤")
    func multiStatusWithForbiddenMemberIsPermissionDenied() async throws {
        let behaviour = TestWebDAVServer.Behaviour(multiStatusOnDelete: true, multiStatusMemberCode: 403)
        try await Self.withService(behaviour: behaviour) { service, server in
            try FileManager.default.createDirectory(
                at: server.rootDirectory.appendingPathComponent("shared"), withIntermediateDirectories: false)
            do {
                try await service.deleteDirectory(at: "/shared")
                Issue.record("expected the delete to be refused")
            } catch RemoteFileServiceError.permissionDenied(_, let path) {
                #expect(path == "/shared")
            }
        }
    }

    @Test("DELETE 的 207 內含其他錯誤時是一般失敗並帶出狀態碼")
    func multiStatusWithOtherMemberIsOperationFailed() async throws {
        try await Self.withService(behaviour: .init(multiStatusOnDelete: true)) { service, server in
            try FileManager.default.createDirectory(
                at: server.rootDirectory.appendingPathComponent("shared"), withIntermediateDirectories: false)
            do {
                try await service.deleteDirectory(at: "/shared")
                Issue.record("expected the delete to fail")
            } catch RemoteFileServiceError.operationFailed(_, _, let underlying) {
                #expect(underlying.contains("423"))
            }
        }
    }

    @Test("連不上伺服器時回報 connectionFailed")
    func unreachableServerIsConnectionFailed() async throws {
        let server = try await TestWebDAVServer.start()
        let port = server.port
        try await server.stop()

        let service = Self.makeService(port: port)
        do {
            try await service.connect()
            Issue.record("expected the connection to fail")
        } catch RemoteFileServiceError.connectionFailed {
        }
    }
}
