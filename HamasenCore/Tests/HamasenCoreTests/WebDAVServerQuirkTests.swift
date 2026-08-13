import Foundation
import Testing
@testable import HamasenCore

/// Behaviours real WebDAV servers exhibit that a uniformly well-behaved fake
/// would hide. Each test here pins a defect that shipped once because the
/// original test server could not reproduce the situation.
@Suite("WebDAV server quirks")
struct WebDAVServerQuirkTests {
    private static func makeService(
        port: Int,
        remotePath: String = RemotePath.root,
        password: String = TestWebDAVServer.password
    ) -> WebDAVFileService {
        WebDAVFileService(
            config: ServerConfig(
                name: "測試 WebDAV",
                transferProtocol: .webdav,
                host: "127.0.0.1",
                port: port,
                username: TestWebDAVServer.username,
                remotePath: remotePath
            ),
            credentials: .password(password)
        )
    }

    // MARK: - Redirects

    @Test("轉址後仍帶著憑證，讀取不會變成認證失敗")
    func restoresCredentialsAcrossRedirect() async throws {
        // The server sends every /dav request to /moved, and still demands
        // Basic auth there — which only succeeds if the header survived.
        let server = try await TestWebDAVServer.start(
            behaviour: .init(redirectFrom: "/dav", redirectTo: "/moved")
        )
        let moved = server.rootDirectory.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        try Data("redirected".utf8).write(to: moved.appendingPathComponent("file.txt"))

        let service = Self.makeService(port: server.port, remotePath: "/dav")
        try await service.connect()

        let contents = try await service.downloadRange(at: "/file.txt", offset: 0, length: 32)
        #expect(String(decoding: contents, as: UTF8.self) == "redirected")

        try await service.disconnect()
        try await server.stop()
    }

    @Test("上傳遇到轉址時明確失敗，而不是靜默寫入空檔")
    func refusesRedirectForUpload() async throws {
        let server = try await TestWebDAVServer.start(
            behaviour: .init(redirectFrom: "/dav", redirectTo: "/moved")
        )
        let moved = server.rootDirectory.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)

        let service = Self.makeService(port: server.port, remotePath: "/dav")
        try await service.connect()

        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-\(UUID().uuidString).txt")
        try Data("content that must not be lost".utf8).write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }

        await #expect(throws: RemoteFileServiceError.self) {
            try await service.uploadFile(from: localURL, to: "/uploaded.txt")
        }
        // Nothing was written anywhere, rather than an empty file appearing.
        #expect(!FileManager.default.fileExists(atPath: moved.appendingPathComponent("uploaded.txt").path))

        try await service.disconnect()
        try await server.stop()
    }

    // MARK: - Range handling

    @Test("伺服器忽略 Range 時只下載一次整檔")
    func downloadsWholeEntityOnceWhenRangeIsIgnored() async throws {
        let server = try await TestWebDAVServer.start(behaviour: .init(ignoresRange: true))
        let payload = Data((0..<40_000).map { UInt8($0 % 251) })
        try payload.write(to: server.rootDirectory.appendingPathComponent("big.bin"))

        let service = Self.makeService(port: server.port)
        try await service.connect()

        // Three separate chunks of the same file.
        for offset in stride(from: 0, to: 30_000, by: 10_000) {
            let chunk = try await service.downloadRange(at: "/big.bin", offset: Int64(offset), length: 10_000)
            #expect(chunk == payload.subdata(in: offset..<(offset + 10_000)))
        }

        // One GET for all three, because the whole entity was retained.
        #expect(server.requestCount(method: "GET") == 1)

        try await service.disconnect()
        try await server.stop()
    }

    @Test("區間起點超過檔尾時回傳空資料，而非錯誤")
    func treatsRangeBeyondEndAsShortRead() async throws {
        let server = try await TestWebDAVServer.start()
        try Data("short".utf8).write(to: server.rootDirectory.appendingPathComponent("short.txt"))

        let service = Self.makeService(port: server.port)
        try await service.connect()

        // The server answers 416; the contract says a short read, matching SFTP.
        let past = try await service.downloadRange(at: "/short.txt", offset: 50, length: 10)
        #expect(past.isEmpty)

        try await service.disconnect()
        try await server.stop()
    }

    // MARK: - Status handling

    @Test("DELETE 回 207 時視為失敗，不謊報成功")
    func treatsMultiStatusDeleteAsFailure() async throws {
        let server = try await TestWebDAVServer.start(behaviour: .init(multiStatusOnDelete: true))
        try FileManager.default.createDirectory(
            at: server.rootDirectory.appendingPathComponent("shared"),
            withIntermediateDirectories: false
        )

        let service = Self.makeService(port: server.port)
        try await service.connect()

        await #expect(throws: RemoteFileServiceError.self) {
            try await service.deleteDirectory(at: "/shared")
        }
        // The directory really is still there, which is what 207 meant.
        #expect(FileManager.default.fileExists(
            atPath: server.rootDirectory.appendingPathComponent("shared").path
        ))

        try await service.disconnect()
        try await server.stop()
    }

    @Test("唯讀分享回 403 時是權限錯誤，不是認證失敗")
    func treatsForbiddenAsPermissionError() async throws {
        let server = try await TestWebDAVServer.start(behaviour: .init(forbidsWrites: true))
        let service = Self.makeService(port: server.port)
        try await service.connect()

        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ro-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }

        // authenticationFailed would put the whole Finder domain into a
        // re-authentication state over one unwritable folder.
        await #expect(throws: RemoteFileServiceError.self) {
            do {
                try await service.uploadFile(from: localURL, to: "/nope.txt")
            } catch RemoteFileServiceError.authenticationFailed {
                Issue.record("403 must not be reported as an authentication failure")
                throw RemoteFileServiceError.authenticationFailed
            }
        }

        try await service.disconnect()
        try await server.stop()
    }

    @Test("目的地已存在時移動失敗，不覆蓋既有檔案")
    func refusesToOverwriteOnMove() async throws {
        let server = try await TestWebDAVServer.start()
        try Data("source".utf8).write(to: server.rootDirectory.appendingPathComponent("a.txt"))
        try Data("must survive".utf8).write(to: server.rootDirectory.appendingPathComponent("b.txt"))

        let service = Self.makeService(port: server.port)
        try await service.connect()

        await #expect(throws: RemoteFileServiceError.self) {
            try await service.moveItem(from: "/a.txt", to: "/b.txt")
        }
        let destination = try String(
            contentsOf: server.rootDirectory.appendingPathComponent("b.txt"), encoding: .utf8
        )
        #expect(destination == "must survive")

        try await service.disconnect()
        try await server.stop()
    }

    // MARK: - Missing metadata

    @Test("伺服器不回報檔案大小時視為未知")
    func reportsUnknownSizeAsZero() async throws {
        let server = try await TestWebDAVServer.start(behaviour: .init(omitsContentLength: true))
        try Data("some bytes".utf8).write(to: server.rootDirectory.appendingPathComponent("a.txt"))

        let service = Self.makeService(port: server.port)
        try await service.connect()

        // The extension treats a zero size as "unknown" and fetches the whole
        // item rather than aligning a range against it.
        let info = try await service.itemInfo(at: "/a.txt")
        #expect(info.size == 0)

        // The bytes are still reachable through a full download.
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("unknown-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: localURL) }
        try await service.downloadFile(at: "/a.txt", to: localURL)
        #expect(try String(contentsOf: localURL, encoding: .utf8) == "some bytes")

        try await service.disconnect()
        try await server.stop()
    }

    // MARK: - Session lifecycle

    @Test("斷線與進行中的請求並行時不會讓行程崩潰")
    func survivesDisconnectRacingRequests() async throws {
        let server = try await TestWebDAVServer.start()
        for index in 0..<20 {
            try Data("payload \(index)".utf8)
                .write(to: server.rootDirectory.appendingPathComponent("f\(index).txt"))
        }

        let service = Self.makeService(port: server.port)
        try await service.connect()

        // Requests in flight while the service is torn down used to create a
        // task on an invalidated session, an uncatchable ObjC exception.
        async let readers: Void = withTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    _ = try? await service.downloadRange(at: "/f\(index).txt", offset: 0, length: 64)
                }
            }
        }
        try await service.disconnect()
        await readers

        try await server.stop()
    }
}
