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

    // MARK: - Interrupted uploads

    /// rclone keeps whatever arrived of a PUT that was cut off, under the
    /// name it was sent to; written in place, that is half of the new file
    /// where the old one was.
    @Test("上傳中途斷線時，原本的檔案保持原樣")
    func anInterruptedUploadLeavesTheOldFile() async throws {
        try await Self.withService(behaviour: .init(dropsPutsAfterBytes: 1_000)) { service, server in
            let target = server.rootDirectory.appendingPathComponent("doc.txt")
            try Data("old contents".utf8).write(to: target)
            let source = try temporaryFile(Data(repeating: 7, count: 100_000))
            defer { try? FileManager.default.removeItem(at: source) }

            await #expect(throws: RemoteFileServiceError.self) {
                try await service.uploadFile(from: source, to: "/doc.txt")
            }
            #expect(try Data(contentsOf: target) == Data("old contents".utf8))
            #expect(try await service.listDirectory(at: RemotePath.root).map(\.name) == ["doc.txt"])
        }
    }

    /// A cancelled upload's task cannot send anything more, so the request
    /// that removes its temporary file has to go out from one of its own.
    @Test("取消的上傳不會在伺服器上留下暫存檔")
    func aCancelledUploadRemovesItsTemporaryFile() async throws {
        try await Self.withService(behaviour: .init(neverAnswersPuts: true)) { service, server in
            let source = try temporaryFile(Data("new contents".utf8))
            defer { try? FileManager.default.removeItem(at: source) }
            let names = { (try? FileManager.default.contentsOfDirectory(atPath: server.rootDirectory.path)) ?? [] }

            let upload = Task { try await service.uploadFile(from: source, to: "/doc.txt") }
            // Cancelled once the temporary file is on the server, so there is
            // something to remove.
            while !names().contains(where: { RemotePath.isTemporaryUpload(name: $0) }) {
                try await Task.sleep(for: .milliseconds(10))
            }
            upload.cancel()
            await #expect(throws: CancellationError.self) { try await upload.value }
            #expect(names().isEmpty)
        }
    }

    /// A server that deletes the destination before renaming can fail the
    /// rename with the old file already gone; the upload under its temporary
    /// name is then the only copy left, and deleting it would lose both.
    @Test("移入原位失敗且舊檔已刪時，保留上傳的暫存檔")
    func aFailedMoveKeepsTheOnlyCopy() async throws {
        try await Self.withService(behaviour: .init(failsMoveAfterDeletingDestination: true)) { service, server in
            try Data("old contents".utf8).write(to: server.rootDirectory.appendingPathComponent("doc.txt"))
            let source = try temporaryFile(Data("new contents".utf8))
            defer { try? FileManager.default.removeItem(at: source) }

            await #expect(throws: RemoteFileServiceError.self) {
                try await service.uploadFile(from: source, to: "/doc.txt")
            }
            let kept = try FileManager.default.contentsOfDirectory(atPath: server.rootDirectory.path)
                .filter { RemotePath.isTemporaryUpload(name: $0) }
            #expect(kept.count == 1)
            #expect(try kept.first.map { try Data(contentsOf: server.rootDirectory.appendingPathComponent($0)) }
                == Data("new contents".utf8))
        }
    }

    /// Putting a finished upload in place replaces what is there, and a
    /// folder that appeared under the name is not a file to replace. Where
    /// the upload is written to the name directly, the server refuses it.
    @Test("上傳到資料夾所在的名稱時拒絕，資料夾保留", arguments: [false, true])
    func anUploadDoesNotReplaceAFolder(behavesLikeNextcloud: Bool) async throws {
        var behaviour = TestWebDAVServer.Behaviour.wellBehaved
        behaviour.behavesLikeNextcloud = behavesLikeNextcloud
        try await Self.withService(behaviour: behaviour) { service, server in
            let folder = server.rootDirectory.appendingPathComponent("taken")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try Data("inside".utf8).write(to: folder.appendingPathComponent("inside.txt"))
            let source = try temporaryFile(Data("new".utf8))
            defer { try? FileManager.default.removeItem(at: source) }

            await #expect(throws: RemoteFileServiceError.self) {
                try await service.uploadFile(from: source, to: "/taken")
            }
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("inside.txt").path))
            #expect(try await service.listDirectory(at: RemotePath.root).map(\.name) == ["taken"])
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
        } catch RemoteFileServiceError.connectionFailed(let underlying) {
            // The system's text for a refused connection only repeats the
            // error's own, so the message carries no detail after it.
            #expect(underlying.isEmpty)
        }
    }
}
