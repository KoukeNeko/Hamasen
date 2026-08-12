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
