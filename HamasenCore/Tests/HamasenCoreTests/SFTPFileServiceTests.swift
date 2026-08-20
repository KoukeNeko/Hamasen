import Foundation
import Testing
@testable import HamasenCore

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
            credentials: .password(TestSFTPServer.password)
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
            credentials: .password(TestSFTPServer.password)
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
        let service = SFTPFileService(config: config, credentials: .password("wrong-password"))

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
            credentials: .privateKey(openSSHKey: server.authorizedClientKey, passphrase: nil)
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
            credentials: .privateKey(openSSHKey: SSHKeyFixtures.ed25519Plain, passphrase: nil)
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
            credentials: .privateKey(openSSHKey: SSHKeyFixtures.ed25519Encrypted, passphrase: nil)
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
            credentials: .privateKey(openSSHKey: SSHKeyFixtures.ed25519Encrypted, passphrase: "wrong")
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
        let service = SFTPFileService(config: config, credentials: .password(TestSFTPServer.password))
        try await service.connect()

        let items = try await service.listDirectory(at: RemotePath.root)
        #expect(items.map(\.name) == ["scoped.txt"])

        try await Self.tearDown(service, server)
    }
}
