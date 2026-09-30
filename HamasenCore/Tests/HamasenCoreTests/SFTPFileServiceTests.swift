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
import HamasenTestServers

/// End-to-end tests for SFTPFileService against the in-process SFTP server.
@Suite("SFTPFileService")
struct SFTPFileServiceTests {
    /// Returns a connected service plus its test server; callers tear both
    /// down at the end of the test.
    private static func makeConnectedService() async throws -> (SFTPFileService, TestSFTPServer) {
        let server = try await TestSFTPServer.start()
        let config = ServerConfig(
            name: "測試伺服器",
            host: "127.0.0.1",
            port: server.port,
            username: TestSFTPServer.username
        )
        let service = SFTPFileService(
            config: config,
            credentials: .password(TestSFTPServer.password),
            hostKeyPolicy: .acceptAnything
        )
        try await service.connect()
        return (service, server)
    }

    private static func tearDown(_ service: SFTPFileService, _ server: TestSFTPServer) async throws {
        try await service.disconnect()
        try await server.stop()
    }

    @Test("連線與登入")
    func connectAndAuthenticate() async throws {
        let (service, server) = try await Self.makeConnectedService()
        try await Self.tearDown(service, server)
    }

    /// What the File Provider's connection registry asks before handing a
    /// cached connection to the next request. A session can go away with
    /// nobody watching — the server drops an idle one, the machine sleeps —
    /// and a registry that cannot tell keeps serving the dead one, failing
    /// every request until the extension restarts.
    ///
    /// The peer-vanished case is not reproducible here: the in-process
    /// server's close stops its listener and leaves established connections
    /// up. What is covered is the property the registry reads, over the
    /// transitions this harness can produce.
    @Test("未連線與已連線的狀態分得開")
    func reportsWhetherItIsConnected() async throws {
        let server = try await TestSFTPServer.start()
        let config = ServerConfig(
            name: "測試伺服器",
            host: "127.0.0.1",
            port: server.port,
            username: TestSFTPServer.username
        )
        let service = SFTPFileService(
            config: config,
            credentials: .password(TestSFTPServer.password),
            hostKeyPolicy: .acceptAnything
        )

        #expect(await service.isConnected == false)
        try await service.connect()
        #expect(await service.isConnected == true)

        // Returns without waiting on a close the peer may never answer, so
        // reaching the next line at all is part of what is being checked.
        try await service.disconnect()
        #expect(await service.isConnected == false)

        try await server.stop()
    }

    @Test("密碼錯誤時登入失敗")
    func authenticationFailsWithWrongPassword() async throws {
        let server = try await TestSFTPServer.start()

        let config = ServerConfig(
            name: "測試伺服器",
            host: "127.0.0.1",
            port: server.port,
            username: TestSFTPServer.username
        )
        let service = SFTPFileService(
            config: config,
            credentials: .password("wrong-password"),
            hostKeyPolicy: .acceptAnything
        )

        await #expect(throws: RemoteFileServiceError.self) {
            try await service.connect()
        }

        try await server.stop()
    }

    @Test("以 SSH 金鑰連線並操作檔案")
    func connectsWithPrivateKey() async throws {
        let server = try await TestSFTPServer.start()
        let config = ServerConfig(
            name: "測試伺服器",
            host: "127.0.0.1",
            port: server.port,
            username: TestSFTPServer.username,
            authenticationMethod: .privateKey
        )
        let service = SFTPFileService(
            config: config,
            credentials: .privateKey(openSSHKey: server.authorizedClientKey, passphrase: nil),
            hostKeyPolicy: .acceptAnything
        )
        try await service.connect()

        try Data("key auth".utf8).write(to: server.rootDirectory.appendingPathComponent("keyed.txt"))
        let items = try await service.listDirectory(at: RemotePath.root)
        #expect(items.map(\.name) == ["keyed.txt"])

        try await Self.tearDown(service, server)
    }

    @Test("金鑰不被伺服器接受時連線失敗")
    func rejectsUnauthorizedPrivateKey() async throws {
        let server = try await TestSFTPServer.start()
        let config = ServerConfig(
            name: "測試伺服器",
            host: "127.0.0.1",
            port: server.port,
            username: TestSFTPServer.username,
            authenticationMethod: .privateKey
        )
        // A well-formed key the server has never authorized.
        let service = SFTPFileService(
            config: config,
            credentials: .privateKey(openSSHKey: SSHKeyFixtures.ed25519Plain, passphrase: nil),
            hostKeyPolicy: .acceptAnything
        )

        await #expect(throws: RemoteFileServiceError.self) {
            try await service.connect()
        }

        try await server.stop()
    }

    @Test("加密金鑰未提供密碼時明確回報")
    func reportsMissingPassphrase() async throws {
        let server = try await TestSFTPServer.start()
        let config = ServerConfig(
            name: "測試伺服器",
            host: "127.0.0.1",
            port: server.port,
            username: TestSFTPServer.username,
            authenticationMethod: .privateKey
        )
        let service = SFTPFileService(
            config: config,
            credentials: .privateKey(openSSHKey: SSHKeyFixtures.ed25519Encrypted, passphrase: nil),
            hostKeyPolicy: .acceptAnything
        )

        await #expect(throws: RemoteFileServiceError.privateKeyPassphraseRequired) {
            try await service.connect()
        }

        try await server.stop()
    }

    @Test("加密金鑰密碼錯誤時明確回報")
    func reportsWrongPassphrase() async throws {
        let server = try await TestSFTPServer.start()
        let config = ServerConfig(
            name: "測試伺服器",
            host: "127.0.0.1",
            port: server.port,
            username: TestSFTPServer.username,
            authenticationMethod: .privateKey
        )
        let service = SFTPFileService(
            config: config,
            credentials: .privateKey(openSSHKey: SSHKeyFixtures.ed25519Encrypted, passphrase: "wrong"),
            hostKeyPolicy: .acceptAnything
        )

        await #expect(throws: RemoteFileServiceError.self) {
            try await service.connect()
        }

        try await server.stop()
    }

    @Test("列出目錄內容並回報正確型別")
    func listDirectoryReturnsFilesAndDirectories() async throws {
        let (service, server) = try await Self.makeConnectedService()

        let fileURL = server.rootDirectory.appendingPathComponent("hello.txt")
        try Data("hello".utf8).write(to: fileURL)
        try FileManager.default.createDirectory(
            at: server.rootDirectory.appendingPathComponent("docs"),
            withIntermediateDirectories: false
        )

        let items = try await service.listDirectory(at: RemotePath.root)

        #expect(items.count == 2)
        let file = try #require(items.first { $0.name == "hello.txt" })
        let directory = try #require(items.first { $0.name == "docs" })
        #expect(file.kind == .file)
        #expect(file.size == 5)
        #expect(file.path == "/hello.txt")
        #expect(directory.kind == .directory)
        #expect(directory.path == "/docs")

        try await Self.tearDown(service, server)
    }

    @Test("下載檔案內容正確")
    func downloadFileMatchesContent() async throws {
        let (service, server) = try await Self.makeConnectedService()

        let expectedContent = "端到端下載測試內容 — Hamasen"
        try Data(expectedContent.utf8).write(
            to: server.rootDirectory.appendingPathComponent("download-me.txt")
        )

        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("downloaded-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: localURL) }

        try await service.downloadFile(at: "/download-me.txt", to: localURL)

        let downloadedContent = try String(contentsOf: localURL, encoding: .utf8)
        #expect(downloadedContent == expectedContent)

        try await Self.tearDown(service, server)
    }

    @Test("讀取指定區間")
    func downloadsByteRange() async throws {
        let (service, server) = try await Self.makeConnectedService()

        let content = "0123456789ABCDEF"
        try Data(content.utf8).write(to: server.rootDirectory.appendingPathComponent("ranged.txt"))

        let middle = try await service.downloadRange(at: "/ranged.txt", offset: 4, length: 6)
        #expect(String(decoding: middle, as: UTF8.self) == "456789")

        let head = try await service.downloadRange(at: "/ranged.txt", offset: 0, length: 4)
        #expect(String(decoding: head, as: UTF8.self) == "0123")

        try await Self.tearDown(service, server)
    }

    @Test("區間超過檔尾時只回傳實際存在的位元組")
    func clampsRangeAtEndOfFile() async throws {
        let (service, server) = try await Self.makeConnectedService()

        try Data("short".utf8).write(to: server.rootDirectory.appendingPathComponent("short.txt"))

        let tail = try await service.downloadRange(at: "/short.txt", offset: 3, length: 100)
        #expect(String(decoding: tail, as: UTF8.self) == "rt")

        let past = try await service.downloadRange(at: "/short.txt", offset: 50, length: 10)
        #expect(past.isEmpty)

        try await Self.tearDown(service, server)
    }

    @Test("大於單次讀取上限的區間會補滿")
    func fillsRangeAcrossMultipleReads() async throws {
        let (service, server) = try await Self.makeConnectedService()

        // Larger than any single SFTP read the server will answer, so the
        // client has to loop to satisfy the request.
        let payload = Data((0..<600_000).map { UInt8($0 % 251) })
        try payload.write(to: server.rootDirectory.appendingPathComponent("large.bin"))

        let ranged = try await service.downloadRange(at: "/large.bin", offset: 1000, length: 500_000)
        #expect(ranged.count == 500_000)
        #expect(ranged == payload.subdata(in: 1000..<501_000))

        try await Self.tearDown(service, server)
    }

    @Test("整檔下載大檔案內容正確")
    func downloadsLargeFileWhole() async throws {
        let (service, server) = try await Self.makeConnectedService()

        let payload = Data((0..<600_000).map { UInt8($0 % 251) })
        try payload.write(to: server.rootDirectory.appendingPathComponent("large.bin"))

        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("large-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: localURL) }

        try await service.downloadFile(at: "/large.bin", to: localURL)
        #expect(try Data(contentsOf: localURL) == payload)

        try await Self.tearDown(service, server)
    }

    @Test("上傳檔案後遠端內容正確")
    func uploadFileWritesRemoteContent() async throws {
        let (service, server) = try await Self.makeConnectedService()

        let expectedContent = "上傳測試：\(UUID().uuidString)"
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-src-\(UUID().uuidString).txt")
        try Data(expectedContent.utf8).write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }

        try await service.uploadFile(from: localURL, to: "/uploaded.txt")

        let remoteContent = try String(
            contentsOf: server.rootDirectory.appendingPathComponent("uploaded.txt"),
            encoding: .utf8
        )
        #expect(remoteContent == expectedContent)

        try await Self.tearDown(service, server)
    }

    @Test("建立與刪除目錄")
    func createAndDeleteDirectory() async throws {
        let (service, server) = try await Self.makeConnectedService()

        try await service.createDirectory(at: "/new-folder")
        var isDirectory: ObjCBool = false
        let existsAfterCreate = FileManager.default.fileExists(
            atPath: server.rootDirectory.appendingPathComponent("new-folder").path,
            isDirectory: &isDirectory
        )
        #expect(existsAfterCreate)
        #expect(isDirectory.boolValue)

        try await service.deleteDirectory(at: "/new-folder")
        let existsAfterDelete = FileManager.default.fileExists(
            atPath: server.rootDirectory.appendingPathComponent("new-folder").path
        )
        #expect(!existsAfterDelete)

        try await Self.tearDown(service, server)
    }


    @Test("刪除非空目錄會連同內容一起移除")
    func deletesDirectoryWithContents() async throws {
        let (service, server) = try await Self.makeConnectedService()

        let tree = server.rootDirectory.appendingPathComponent("tree/nested")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: tree.appendingPathComponent("deep.txt"))
        try Data("b".utf8).write(
            to: server.rootDirectory.appendingPathComponent("tree/shallow.txt")
        )

        try await service.deleteDirectory(at: "/tree")

        #expect(!FileManager.default.fileExists(
            atPath: server.rootDirectory.appendingPathComponent("tree").path
        ))

        try await Self.tearDown(service, server)
    }

    @Test("刪除檔案")
    func deleteFileRemovesRemoteFile() async throws {
        let (service, server) = try await Self.makeConnectedService()

        let fileURL = server.rootDirectory.appendingPathComponent("delete-me.txt")
        try Data("bye".utf8).write(to: fileURL)

        try await service.deleteFile(at: "/delete-me.txt")
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))

        try await Self.tearDown(service, server)
    }

    @Test("刪除不存在的檔案回報 itemNotFound")
    func deleteMissingFileThrowsItemNotFound() async throws {
        let (service, server) = try await Self.makeConnectedService()

        await #expect(throws: RemoteFileServiceError.self) {
            try await service.deleteFile(at: "/does-not-exist.txt")
        }

        try await Self.tearDown(service, server)
    }

    @Test("移動與重新命名")
    func moveItemRenamesRemoteFile() async throws {
        let (service, server) = try await Self.makeConnectedService()

        try Data("content".utf8).write(
            to: server.rootDirectory.appendingPathComponent("old-name.txt")
        )

        try await service.moveItem(from: "/old-name.txt", to: "/new-name.txt")

        #expect(!FileManager.default.fileExists(
            atPath: server.rootDirectory.appendingPathComponent("old-name.txt").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: server.rootDirectory.appendingPathComponent("new-name.txt").path
        ))

        try await Self.tearDown(service, server)
    }

    @Test("remotePath 基準目錄會套用到所有操作")
    func remotePathBaseIsApplied() async throws {
        let server = try await TestSFTPServer.start()

        let baseDirectory = server.rootDirectory.appendingPathComponent("srv/data")
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try Data("scoped".utf8).write(to: baseDirectory.appendingPathComponent("scoped.txt"))

        let config = ServerConfig(
            name: "測試伺服器",
            host: "127.0.0.1",
            port: server.port,
            username: TestSFTPServer.username,
            remotePath: "/srv/data"
        )
        let service = SFTPFileService(
            config: config,
            credentials: .password(TestSFTPServer.password),
            hostKeyPolicy: .acceptAnything
        )
        try await service.connect()

        let items = try await service.listDirectory(at: RemotePath.root)
        #expect(items.map(\.name) == ["scoped.txt"])

        try await Self.tearDown(service, server)
    }

    // MARK: - Transfers

    private static func makeLocalFile(_ payload: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sftp-local-\(UUID().uuidString).bin")
        try payload.write(to: url)
        return url
    }

    /// Patterned so a chunk that lands at the wrong offset or twice cannot
    /// pass for the right one.
    private static func makePayload(byteCount: Int) -> Data {
        Data((0..<byteCount).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8) })
    }

    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var totals: [Int64] = []
        func record(_ total: Int64) { lock.withLock { totals.append(total) } }
        var recorded: [Int64] { lock.withLock { totals } }
    }

    @Test("多 MB 檔案上傳再下載內容一致並回報進度")
    func roundTripsMultiMegabyteFileWithProgress() async throws {
        let (service, server) = try await Self.makeConnectedService()

        let payload = Self.makePayload(byteCount: 5_000_017)
        let source = try Self.makeLocalFile(payload)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("sftp-back-\(UUID().uuidString).bin")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }

        let uploadProgress = ProgressLog()
        try await service.uploadFile(from: source, to: "/big.bin", progress: { uploadProgress.record($0) })
        #expect(try Data(contentsOf: server.rootDirectory.appendingPathComponent("big.bin")) == payload)
        #expect(uploadProgress.recorded == uploadProgress.recorded.sorted())
        #expect(uploadProgress.recorded.last == Int64(payload.count))

        let downloadProgress = ProgressLog()
        try await service.downloadFile(at: "/big.bin", to: destination, progress: { downloadProgress.record($0) })
        #expect(try Data(contentsOf: destination) == payload)
        #expect(downloadProgress.recorded == downloadProgress.recorded.sorted())
        #expect(downloadProgress.recorded.last == Int64(payload.count))

        let ranged = try await service.downloadRange(at: "/big.bin", offset: 123_456, length: 2_000_000)
        #expect(ranged == payload.subdata(in: 123_456..<2_123_456))

        try await Self.tearDown(service, server)
    }

    @Test("取消下載會在傳完前停止")
    func cancellingDownloadStopsEarly() async throws {
        let (service, server) = try await Self.makeConnectedService()

        let payload = Self.makePayload(byteCount: 8_000_000)
        try payload.write(to: server.rootDirectory.appendingPathComponent("cancel-me.bin"))
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("sftp-cancel-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destination) }

        let progress = ProgressLog()
        let task = Task {
            try await service.downloadFile(at: "/cancel-me.bin", to: destination, progress: { progress.record($0) })
        }
        while progress.recorded.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect((progress.recorded.last ?? 0) < Int64(payload.count))

        try await Self.tearDown(service, server)
    }

    @Test("上傳完成後不留暫存檔且會取代舊檔")
    func uploadReplacesExistingFileWithoutLeavingTemporary() async throws {
        let (service, server) = try await Self.makeConnectedService()

        try Data("old".utf8).write(to: server.rootDirectory.appendingPathComponent("target.txt"))
        let source = try Self.makeLocalFile(Data("new content".utf8))
        defer { try? FileManager.default.removeItem(at: source) }

        try await service.uploadFile(from: source, to: "/target.txt")

        let names = try FileManager.default.contentsOfDirectory(atPath: server.rootDirectory.path)
        #expect(names == ["target.txt"])
        #expect(try String(contentsOf: server.rootDirectory.appendingPathComponent("target.txt"), encoding: .utf8) == "new content")

        try await Self.tearDown(service, server)
    }

    @Test("列表不顯示進行中的上傳暫存檔")
    func listingHidesTemporaryUploads() async throws {
        let (service, server) = try await Self.makeConnectedService()

        let temporaryName = RemotePath.name(of: RemotePath.temporaryUploadPath(for: "/report.txt"))
        try Data("partial".utf8).write(to: server.rootDirectory.appendingPathComponent(temporaryName))
        try Data("done".utf8).write(to: server.rootDirectory.appendingPathComponent("report.txt"))

        let items = try await service.listDirectory(at: RemotePath.root)
        #expect(items.map(\.name) == ["report.txt"])

        try await Self.tearDown(service, server)
    }

    // MARK: - Symlinks

    @Test("刪除指向目錄的連結不會刪掉目標內容")
    func deletingDirectoryLinkKeepsTarget() async throws {
        let (service, server) = try await Self.makeConnectedService()

        let target = server.rootDirectory.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: target.appendingPathComponent("precious.txt"))
        try FileManager.default.createSymbolicLink(
            at: server.rootDirectory.appendingPathComponent("link"),
            withDestinationURL: target
        )

        // The link reads as a directory, which is what sends it here.
        #expect(try await service.itemInfo(at: "/link").isDirectory)
        try await service.deleteDirectory(at: "/link")

        #expect(!FileManager.default.fileExists(atPath: server.rootDirectory.appendingPathComponent("link").path))
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("precious.txt").path))

        try await Self.tearDown(service, server)
    }

    @Test("刪除含有目錄連結的目錄只移除連結")
    func deletingDirectoryContainingLinkKeepsLinkTarget() async throws {
        let (service, server) = try await Self.makeConnectedService()

        let target = server.rootDirectory.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: target.appendingPathComponent("precious.txt"))
        let holder = server.rootDirectory.appendingPathComponent("holder")
        try FileManager.default.createDirectory(at: holder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: holder.appendingPathComponent("link"),
            withDestinationURL: target
        )

        try await service.deleteDirectory(at: "/holder")

        #expect(!FileManager.default.fileExists(atPath: holder.path))
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("precious.txt").path))

        try await Self.tearDown(service, server)
    }

    // MARK: - Errors

    @Test("移動到已存在的項目回報 alreadyExists")
    func moveOntoExistingItemThrowsAlreadyExists() async throws {
        let (service, server) = try await Self.makeConnectedService()

        try Data("a".utf8).write(to: server.rootDirectory.appendingPathComponent("a.txt"))
        try Data("b".utf8).write(to: server.rootDirectory.appendingPathComponent("b.txt"))

        await #expect(throws: RemoteFileServiceError.alreadyExists(path: "/b.txt")) {
            try await service.moveItem(from: "/a.txt", to: "/b.txt")
        }
        #expect(try String(contentsOf: server.rootDirectory.appendingPathComponent("b.txt"), encoding: .utf8) == "b")

        try await Self.tearDown(service, server)
    }

    @Test("移動不存在的項目回報 itemNotFound")
    func moveMissingItemThrowsItemNotFound() async throws {
        let (service, server) = try await Self.makeConnectedService()

        await #expect(throws: RemoteFileServiceError.itemNotFound(path: "/missing.txt")) {
            try await service.moveItem(from: "/missing.txt", to: "/other.txt")
        }

        try await Self.tearDown(service, server)
    }

    /// A half-open connection never answers; without a per-request timeout
    /// the download would wait forever while `isConnected` stayed true.
    @Test("伺服器不回應時逾時並標記連線失效")
    func unansweredRequestTimesOutAndDropsSession() async throws {
        let server = try await TestSFTPServer.start()
        let service = SFTPFileService(
            config: ServerConfig(
                name: "測試伺服器",
                host: "127.0.0.1",
                port: server.port,
                username: TestSFTPServer.username
            ),
            credentials: .password(TestSFTPServer.password),
            connectTimeoutSeconds: 1,
            hostKeyPolicy: .acceptAnything
        )
        try await service.connect()

        try Data("stuck".utf8).write(to: server.rootDirectory.appendingPathComponent("stuck.txt"))
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("sftp-stuck-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: destination) }

        server.stallsReads = true
        do {
            try await service.downloadFile(at: "/stuck.txt", to: destination)
            Issue.record("Expected the download to time out")
        } catch let error as RemoteFileServiceError {
            guard case .connectionFailed = error else {
                Issue.record("Expected connectionFailed, got \(error)")
                return
            }
        }
        server.stallsReads = false

        #expect(await service.isConnected == false)

        try await service.disconnect()
        try await server.stop()
    }
}
