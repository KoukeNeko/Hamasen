import Foundation
import Testing
@testable import HamasenCore

/// End-to-end tests for WebDAVFileService against the in-process server.
@Suite("WebDAVFileService")
struct WebDAVFileServiceTests {
    private static func makeConnectedService() async throws -> (WebDAVFileService, TestWebDAVServer) {
        let server = try await TestWebDAVServer.start()
        let service = WebDAVFileService(
            config: makeConfig(port: server.port),
            credentials: .password(TestWebDAVServer.password)
        )
        try await service.connect()
        return (service, server)
    }

    private static func makeConfig(port: Int, remotePath: String = RemotePath.root) -> ServerConfig {
        ServerConfig(
            name: "測試 WebDAV",
            transferProtocol: .webdav,
            host: "127.0.0.1",
            port: port,
            username: TestWebDAVServer.username,
            remotePath: remotePath
        )
    }

    private static func tearDown(_ service: WebDAVFileService, _ server: TestWebDAVServer) async throws {
        try await service.disconnect()
        try await server.stop()
    }

    @Test("連線與認證")
    func connectsAndAuthenticates() async throws {
        let (service, server) = try await Self.makeConnectedService()
        try await Self.tearDown(service, server)
    }

    @Test("密碼錯誤時認證失敗")
    func rejectsWrongPassword() async throws {
        let server = try await TestWebDAVServer.start()
        let service = WebDAVFileService(
            config: Self.makeConfig(port: server.port),
            credentials: .password("wrong")
        )

        await #expect(throws: RemoteFileServiceError.authenticationFailed) {
            try await service.connect()
        }

        try await server.stop()
    }

    @Test("收到金鑰憑證時明確回報不支援，而非送出未認證請求")
    func rejectsPrivateKeyCredentials() async throws {
        let server = try await TestWebDAVServer.start()
        let service = WebDAVFileService(
            config: Self.makeConfig(port: server.port),
            credentials: .privateKey(openSSHKey: SSHKeyFixtures.ed25519Plain, passphrase: nil)
        )

        await #expect(throws: RemoteFileServiceError.unsupportedCredentials(protocolName: "WebDAV")) {
            try await service.connect()
        }

        try await server.stop()
    }

    @Test("斷線後可重新連線")
    func reconnectsAfterDisconnect() async throws {
        let (service, server) = try await Self.makeConnectedService()

        try await service.disconnect()
        try await service.connect()
        _ = try await service.listDirectory(at: RemotePath.root)

        try await Self.tearDown(service, server)
    }

    @Test("斷線後操作回報未連線，而非讓行程崩潰")
    func reportsNotConnectedAfterDisconnect() async throws {
        let (service, server) = try await Self.makeConnectedService()
        try await service.disconnect()

        await #expect(throws: RemoteFileServiceError.notConnected) {
            _ = try await service.listDirectory(at: RemotePath.root)
        }

        try await server.stop()
    }

    @Test("連線失敗後不會留下半連線狀態")
    func leavesNoSessionAfterFailedConnect() async throws {
        let server = try await TestWebDAVServer.start()
        let service = WebDAVFileService(
            config: Self.makeConfig(port: server.port),
            credentials: .password("wrong")
        )

        await #expect(throws: RemoteFileServiceError.authenticationFailed) {
            try await service.connect()
        }
        // A failed connect must not leave a session behind, so the next call
        // reports "not connected" rather than reusing a dead one.
        await #expect(throws: RemoteFileServiceError.notConnected) {
            _ = try await service.listDirectory(at: RemotePath.root)
        }

        try await server.stop()
    }

    @Test("列出目錄並回報型別，且不含目錄自身")
    func listsDirectoryWithoutSelf() async throws {
        let (service, server) = try await Self.makeConnectedService()

        try Data("hello".utf8).write(to: server.rootDirectory.appendingPathComponent("hello.txt"))
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

        try await Self.tearDown(service, server)
    }

    @Test("名稱含空白與符號時路徑正確")
    func handlesEncodedNames() async throws {
        let (service, server) = try await Self.makeConnectedService()

        try Data("x".utf8).write(to: server.rootDirectory.appendingPathComponent("my report +1.txt"))

        let items = try await service.listDirectory(at: RemotePath.root)
        #expect(items.map(\.name) == ["my report +1.txt"])

        let info = try await service.itemInfo(at: "/my report +1.txt")
        #expect(info.size == 1)

        try await Self.tearDown(service, server)
    }

    @Test("檔名含 URL 保留字元時仍可列出與讀取")
    func handlesReservedCharactersInNames() async throws {
        let (service, server) = try await Self.makeConnectedService()

        // "&" also has to survive XML escaping in the PROPFIND response, and
        // "#"/"?" must not be mistaken for URL fragment or query delimiters.
        let names = ["a#b.txt", "q?x.txt", "100%.txt", "a&b.txt"]
        for name in names {
            try Data(name.utf8).write(to: server.rootDirectory.appendingPathComponent(name))
        }

        let items = try await service.listDirectory(at: RemotePath.root)
        #expect(Set(items.map(\.name)) == Set(names))

        for name in names {
            let contents = try await service.downloadRange(at: "/\(name)", offset: 0, length: 64)
            #expect(String(decoding: contents, as: UTF8.self) == name)
        }

        try await Self.tearDown(service, server)
    }

    @Test("下載檔案內容正確")
    func downloadsFile() async throws {
        let (service, server) = try await Self.makeConnectedService()

        let expected = "WebDAV 下載測試"
        try Data(expected.utf8).write(to: server.rootDirectory.appendingPathComponent("get.txt"))

        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dav-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: localURL) }

        try await service.downloadFile(at: "/get.txt", to: localURL)
        #expect(try String(contentsOf: localURL, encoding: .utf8) == expected)

        try await Self.tearDown(service, server)
    }

    @Test("讀取指定區間")
    func downloadsByteRange() async throws {
        let (service, server) = try await Self.makeConnectedService()

        try Data("0123456789ABCDEF".utf8)
            .write(to: server.rootDirectory.appendingPathComponent("ranged.txt"))

        let middle = try await service.downloadRange(at: "/ranged.txt", offset: 4, length: 6)
        #expect(String(decoding: middle, as: UTF8.self) == "456789")

        try await Self.tearDown(service, server)
    }

    @Test("區間超過檔尾時截斷")
    func clampsRangeAtEndOfFile() async throws {
        let (service, server) = try await Self.makeConnectedService()

        try Data("short".utf8).write(to: server.rootDirectory.appendingPathComponent("short.txt"))

        let tail = try await service.downloadRange(at: "/short.txt", offset: 3, length: 100)
        #expect(String(decoding: tail, as: UTF8.self) == "rt")

        try await Self.tearDown(service, server)
    }

    @Test("上傳檔案")
    func uploadsFile() async throws {
        let (service, server) = try await Self.makeConnectedService()

        let expected = "上傳：\(UUID().uuidString)"
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dav-src-\(UUID().uuidString).txt")
        try Data(expected.utf8).write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }

        try await service.uploadFile(from: localURL, to: "/uploaded.txt")

        let remote = try String(
            contentsOf: server.rootDirectory.appendingPathComponent("uploaded.txt"),
            encoding: .utf8
        )
        #expect(remote == expected)

        try await Self.tearDown(service, server)
    }

    @Test("建立與刪除目錄")
    func createsAndDeletesDirectory() async throws {
        let (service, server) = try await Self.makeConnectedService()

        try await service.createDirectory(at: "/new-folder")
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(
            atPath: server.rootDirectory.appendingPathComponent("new-folder").path,
            isDirectory: &isDirectory
        ))
        #expect(isDirectory.boolValue)

        try await service.deleteDirectory(at: "/new-folder")
        #expect(!FileManager.default.fileExists(
            atPath: server.rootDirectory.appendingPathComponent("new-folder").path
        ))

        try await Self.tearDown(service, server)
    }

    @Test("刪除檔案")
    func deletesFile() async throws {
        let (service, server) = try await Self.makeConnectedService()

        let fileURL = server.rootDirectory.appendingPathComponent("delete-me.txt")
        try Data("bye".utf8).write(to: fileURL)

        try await service.deleteFile(at: "/delete-me.txt")
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))

        try await Self.tearDown(service, server)
    }

    @Test("刪除不存在的項目回報 itemNotFound")
    func reportsMissingItem() async throws {
        let (service, server) = try await Self.makeConnectedService()

        await #expect(throws: RemoteFileServiceError.itemNotFound(path: "/nope.txt")) {
            try await service.deleteFile(at: "/nope.txt")
        }

        try await Self.tearDown(service, server)
    }

    @Test("移動與重新命名")
    func movesItem() async throws {
        let (service, server) = try await Self.makeConnectedService()

        try Data("content".utf8).write(to: server.rootDirectory.appendingPathComponent("old.txt"))

        try await service.moveItem(from: "/old.txt", to: "/new.txt")

        #expect(!FileManager.default.fileExists(
            atPath: server.rootDirectory.appendingPathComponent("old.txt").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: server.rootDirectory.appendingPathComponent("new.txt").path
        ))

        try await Self.tearDown(service, server)
    }

    @Test("remotePath 基準目錄會套用到所有操作")
    func appliesRemotePathBase() async throws {
        let server = try await TestWebDAVServer.start()

        let base = server.rootDirectory.appendingPathComponent("dav/data")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try Data("scoped".utf8).write(to: base.appendingPathComponent("scoped.txt"))

        let service = WebDAVFileService(
            config: Self.makeConfig(port: server.port, remotePath: "/dav/data"),
            credentials: .password(TestWebDAVServer.password)
        )
        try await service.connect()

        let items = try await service.listDirectory(at: RemotePath.root)
        #expect(items.map(\.name) == ["scoped.txt"])
        #expect(items.map(\.path) == ["/scoped.txt"])

        try await Self.tearDown(service, server)
    }
}
