import Foundation
import Testing
@testable import HamasenCore
import HamasenTestServers

/// End-to-end tests for FTPFileService against the in-process FTP server.
///
/// This is where the control connection, the passive data connection and the
/// two-part end of a transfer are exercised: none of them can be checked by
/// reading a reply on its own.
@Suite("FTPFileService")
struct FTPFileServiceTests {
    private static func makeConnectedService(
        advertisingMLSD: Bool = true,
        remotePath: String = "/"
    ) async throws -> (FTPFileService, TestFTPServer) {
        let server = try await TestFTPServer.start(advertisingMLSD: advertisingMLSD)
        let service = FTPFileService(
            config: ServerConfig(
                name: "測試伺服器",
                transferProtocol: .ftp,
                host: "127.0.0.1",
                port: server.port,
                username: TestFTPServer.username,
                remotePath: remotePath
            ),
            credentials: .password(TestFTPServer.password)
        )
        try await service.connect()
        return (service, server)
    }

    private static func tearDown(_ service: FTPFileService, _ server: TestFTPServer) async throws {
        try await service.disconnect()
        try await server.stop()
    }

    private static func write(_ contents: String, to name: String, in server: TestFTPServer) throws {
        try Data(contents.utf8).write(to: server.rootDirectory.appendingPathComponent(name))
    }

    @Test("連線與登入")
    func connectAndAuthenticate() async throws {
        let (service, server) = try await Self.makeConnectedService()
        #expect(await service.isConnected)
        try await Self.tearDown(service, server)
    }

    @Test("密碼錯誤時登入失敗")
    func authenticationFailsWithWrongPassword() async throws {
        let server = try await TestFTPServer.start()
        let service = FTPFileService(
            config: ServerConfig(
                name: "測試伺服器",
                transferProtocol: .ftp,
                host: "127.0.0.1",
                port: server.port,
                username: TestFTPServer.username
            ),
            credentials: .password("wrong-password")
        )

        await #expect(throws: RemoteFileServiceError.self) {
            try await service.connect()
        }
        try await server.stop()
    }

    @Test("列出目錄並回報型別")
    func listsADirectory() async throws {
        let (service, server) = try await Self.makeConnectedService()
        try Self.write("hello", to: "notes.txt", in: server)
        try FileManager.default.createDirectory(
            at: server.rootDirectory.appendingPathComponent("archive"), withIntermediateDirectories: false
        )

        let items = try await service.listDirectory(at: "/")
        #expect(Set(items.map(\.name)) == ["notes.txt", "archive"])
        #expect(items.first { $0.name == "archive" }?.kind == .directory)
        #expect(items.first { $0.name == "notes.txt" }?.size == 5)

        try await Self.tearDown(service, server)
    }

    /// Plenty of servers have no MLSD, and the client then has to read what
    /// the directory tool printed.
    @Test("伺服器沒有 MLSD 時改讀 LIST")
    func fallsBackToTheUnixListing() async throws {
        let (service, server) = try await Self.makeConnectedService(advertisingMLSD: false)
        try Self.write("hello", to: "notes.txt", in: server)

        let items = try await service.listDirectory(at: "/")
        #expect(items.map(\.name) == ["notes.txt"])
        #expect(items.first?.size == 5)

        try await Self.tearDown(service, server)
    }

    @Test("下載檔案內容正確")
    func downloadsAFile() async throws {
        let (service, server) = try await Self.makeConnectedService()
        try Self.write("the quick brown fox", to: "notes.txt", in: server)

        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftp-download-\(UUID().uuidString)")
        try await service.downloadFile(at: "/notes.txt", to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }

        #expect(try String(contentsOf: localURL, encoding: .utf8) == "the quick brown fox")
        try await Self.tearDown(service, server)
    }

    /// The system asks for the bytes it needs when a large file is opened,
    /// which FTP serves with REST and a truncated read.
    @Test("讀取指定區間")
    func downloadsAByteRange() async throws {
        let (service, server) = try await Self.makeConnectedService()
        try Self.write("0123456789", to: "digits.txt", in: server)

        let range = try await service.downloadRange(at: "/digits.txt", offset: 3, length: 4)
        #expect(String(decoding: range, as: UTF8.self) == "3456")

        try await Self.tearDown(service, server)
    }

    /// The range API exists so opening a large file does not fetch all of
    /// it. This checks the bytes are the right ones; that the transfer stops
    /// once it has them is structural — the connection is closed — and not
    /// observable from here.
    @Test("大檔案深處的小區間取得正確")
    func downloadsARangeFromDeepInsideALargeFile() async throws {
        let (service, server) = try await Self.makeConnectedService()
        var contents = Data()
        while contents.count < 4_000_000 {
            contents.append(contentsOf: Array("0123456789".utf8))
        }
        contents.replaceSubrange(1_000_000..<1_000_005, with: Array("MARK!".utf8))
        try contents.write(to: server.rootDirectory.appendingPathComponent("large.bin"))

        let range = try await service.downloadRange(at: "/large.bin", offset: 1_000_000, length: 5)
        #expect(String(decoding: range, as: UTF8.self) == "MARK!")

        try await Self.tearDown(service, server)
    }

    @Test("上傳檔案")
    func uploadsAFile() async throws {
        let (service, server) = try await Self.makeConnectedService()
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftp-upload-\(UUID().uuidString)")
        try Data("uploaded".utf8).write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }

        try await service.uploadFile(from: localURL, to: "/uploaded.txt")

        let stored = server.rootDirectory.appendingPathComponent("uploaded.txt")
        #expect(try String(contentsOf: stored, encoding: .utf8) == "uploaded")
        try await Self.tearDown(service, server)
    }

    @Test("建立與刪除目錄")
    func createsAndDeletesADirectory() async throws {
        let (service, server) = try await Self.makeConnectedService()
        try await service.createDirectory(at: "/new")
        #expect(FileManager.default.fileExists(atPath: server.rootDirectory.appendingPathComponent("new").path))

        try await service.deleteDirectory(at: "/new")
        #expect(!FileManager.default.fileExists(atPath: server.rootDirectory.appendingPathComponent("new").path))
        try await Self.tearDown(service, server)
    }

    /// FTP has no command that removes a directory with anything in it, so
    /// the client has to walk it.
    @Test("刪除非空目錄會連同內容一起移除")
    func deletesADirectoryWithContents() async throws {
        let (service, server) = try await Self.makeConnectedService()
        let directory = server.rootDirectory.appendingPathComponent("full")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data("x".utf8).write(to: directory.appendingPathComponent("inside.txt"))

        try await service.deleteDirectory(at: "/full")
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        try await Self.tearDown(service, server)
    }

    @Test("移動與重新命名")
    func movesAnItem() async throws {
        let (service, server) = try await Self.makeConnectedService()
        try Self.write("hello", to: "before.txt", in: server)

        try await service.moveItem(from: "/before.txt", to: "/after.txt")
        #expect(FileManager.default.fileExists(atPath: server.rootDirectory.appendingPathComponent("after.txt").path))
        try await Self.tearDown(service, server)
    }

    @Test("刪除檔案")
    func deletesAFile() async throws {
        let (service, server) = try await Self.makeConnectedService()
        try Self.write("hello", to: "notes.txt", in: server)

        try await service.deleteFile(at: "/notes.txt")
        #expect(!FileManager.default.fileExists(atPath: server.rootDirectory.appendingPathComponent("notes.txt").path))
        try await Self.tearDown(service, server)
    }

    @Test("取得單一項目的資訊")
    func readsItemInfo() async throws {
        let (service, server) = try await Self.makeConnectedService()
        try Self.write("hello", to: "notes.txt", in: server)

        let file = try await service.itemInfo(at: "/notes.txt")
        #expect(file.kind == .file)
        #expect(file.size == 5)
        #expect(file.name == "notes.txt")

        try await Self.tearDown(service, server)
    }

    @Test("remotePath 基準目錄會套用到所有操作")
    func appliesTheMountRoot() async throws {
        let server = try await TestFTPServer.start()
        let base = server.rootDirectory.appendingPathComponent("base")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        try Data("inside".utf8).write(to: base.appendingPathComponent("inside.txt"))

        let service = FTPFileService(
            config: ServerConfig(
                name: "測試伺服器",
                transferProtocol: .ftp,
                host: "127.0.0.1",
                port: server.port,
                username: TestFTPServer.username,
                remotePath: "/base"
            ),
            credentials: .password(TestFTPServer.password)
        )
        try await service.connect()

        let items = try await service.listDirectory(at: "/")
        #expect(items.map(\.name) == ["inside.txt"])

        try await Self.tearDown(service, server)
    }

    @Test("斷線後不再視為已連線")
    func reportsDisconnection() async throws {
        let (service, server) = try await Self.makeConnectedService()
        try await service.disconnect()
        #expect(await service.isConnected == false)
        try await server.stop()
    }
}
