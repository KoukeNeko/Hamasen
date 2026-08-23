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

/// The default search, which visits directories because the protocol offers
/// nothing better. Exercised over SFTP; every protocol without a search call
/// shares this one implementation.
@Suite("Walking search")
struct WalkingSearchTests {
    private static func makeConnectedService() async throws -> (SFTPFileService, TestSFTPServer) {
        let server = try await TestSFTPServer.start()
        let service = SFTPFileService(
            config: ServerConfig(
                name: "測試伺服器", host: "127.0.0.1", port: server.port,
                username: TestSFTPServer.username),
            credentials: .password(TestSFTPServer.password),
            hostKeyPolicy: .acceptAnything)
        try await service.connect()
        return (service, server)
    }

    private static func seed(_ server: TestSFTPServer) throws {
        let root = server.rootDirectory
        for directory in ["Designs", "Designs/2026", "Releases"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        for file in ["report.pdf", "Designs/report-draft.pdf", "Designs/palette.png",
                     "Designs/2026/年度報告.pdf", "Releases/notes.md"] {
            try Data("x".utf8).write(to: root.appendingPathComponent(file))
        }
    }

    @Test("找得到巢狀目錄裡的檔案")
    func findsMatchesAtEveryDepth() async throws {
        let (service, server) = try await Self.makeConnectedService()
        try Self.seed(server)

        let found = try await service.searchItems(matching: "report", under: "/", limit: 50)
        #expect(Set(found.map(\.path)) == [
            "/report.pdf",
            "/Designs/report-draft.pdf",
        ])

        try await service.disconnect()
        try await server.stop()
    }

    /// Finder's own comparison: case and accents do not have to match.
    @Test("大小寫與變音符號不需相符")
    func matchesTheWayFinderDoes() async throws {
        let (service, server) = try await Self.makeConnectedService()
        try Self.seed(server)

        let found = try await service.searchItems(matching: "REPORT", under: "/", limit: 50)
        #expect(found.count == 2)

        try await service.disconnect()
        try await server.stop()
    }

    @Test("非 ASCII 的名稱也找得到")
    func findsANonASCIIName() async throws {
        let (service, server) = try await Self.makeConnectedService()
        try Self.seed(server)

        let found = try await service.searchItems(matching: "年度", under: "/", limit: 50)
        #expect(found.map(\.path) == ["/Designs/2026/年度報告.pdf"])

        try await service.disconnect()
        try await server.stop()
    }

    @Test("只搜尋指定的子樹")
    func searchesOnlyBelowTheGivenPath() async throws {
        let (service, server) = try await Self.makeConnectedService()
        try Self.seed(server)

        let found = try await service.searchItems(matching: "report", under: "/Releases", limit: 50)
        #expect(found.isEmpty)

        try await service.disconnect()
        try await server.stop()
    }

    /// The limit is what stops a walk, so it has to actually stop it.
    @Test("到達上限就停")
    func stopsAtTheLimit() async throws {
        let (service, server) = try await Self.makeConnectedService()
        try Self.seed(server)

        let found = try await service.searchItems(matching: "report", under: "/", limit: 1)
        #expect(found.count == 1)

        try await service.disconnect()
        try await server.stop()
    }

    @Test("空查詢不搜尋任何東西")
    func anEmptyQueryFindsNothing() async throws {
        let (service, server) = try await Self.makeConnectedService()
        try Self.seed(server)

        #expect(try await service.searchItems(matching: "   ", under: "/", limit: 50).isEmpty)
        #expect(try await service.searchItems(matching: "report", under: "/", limit: 0).isEmpty)

        try await service.disconnect()
        try await server.stop()
    }

    /// The system starts a new query on every keystroke. A walk that ignored
    /// cancellation would leave one request in flight per character typed.
    @Test("取消會中止走訪")
    func cancellationStopsTheWalk() async throws {
        let (service, server) = try await Self.makeConnectedService()
        try Self.seed(server)

        let task = Task {
            try await service.searchItems(matching: "report", under: "/", limit: 50)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }

        try await service.disconnect()
        try await server.stop()
    }
}

/// S3 replaces the walk, because a bucket can be searched for real.
@Suite("Bucket search")
struct BucketSearchTests {
    private func withService(
        remotePath: String = "/\(TestS3Server.bucket)",
        _ work: (S3FileService, TestS3Server) async throws -> Void
    ) async throws {
        let server = try await TestS3Server.start()
        let service = S3FileService(
            config: ServerConfig(
                name: "測試 S3", transferProtocol: .s3, host: "127.0.0.1", port: 443,
                username: TestS3Server.credentials.accessKeyID, remotePath: remotePath),
            credentials: .password(TestS3Server.credentials.secretAccessKey),
            endpoint: server.endpoint)
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

    private func seed(_ server: TestS3Server) {
        for key in ["index.html", "assets/app-4f9c2b1e.js", "assets/style-a1b2c3d4.css",
                    "logs/access/2026/08/23/access-2026-08-23.log.gz",
                    "logs/access/2026/08/22/access-2026-08-22.log.gz",
                    "archive/"] {
            server.store.put(Data(key.utf8), forKey: key)
        }
    }

    @Test("一次列舉就涵蓋整棵子樹")
    func oneListingCoversTheWholeSubtree() async throws {
        try await withService { service, server in
            seed(server)
            let before = server.store.listingCount

            let found = try await service.searchItems(matching: "access", under: "/", limit: 50)
            #expect(Set(found.map(\.path)) == [
                "/logs/access/2026/08/22/access-2026-08-22.log.gz",
                "/logs/access/2026/08/23/access-2026-08-23.log.gz",
            ])
            // A walk would have listed the root, logs, access, 2026, 08 and
            // both day folders. This is the difference the override exists for.
            #expect(server.store.listingCount - before == 1)
        }
    }

    /// A folder marker is the folder itself, and has no name to be found by.
    @Test("空資料夾的標記不會出現在結果裡")
    func theFolderMarkerIsNotAResult() async throws {
        try await withService { service, server in
            seed(server)
            let found = try await service.searchItems(matching: "archive", under: "/", limit: 50)
            #expect(found.isEmpty)
        }
    }

    @Test("結果的路徑是掛載點相對的")
    func resultsCarryMountRelativePaths() async throws {
        try await withService(remotePath: "/\(TestS3Server.bucket)/logs") { service, server in
            seed(server)
            let found = try await service.searchItems(matching: "2026-08-23", under: "/", limit: 50)
            #expect(found.map(\.path) == ["/access/2026/08/23/access-2026-08-23.log.gz"])
        }
    }

    @Test("到達上限就停")
    func stopsAtTheLimit() async throws {
        try await withService { service, server in
            seed(server)
            let found = try await service.searchItems(matching: "access", under: "/", limit: 1)
            #expect(found.count == 1)
        }
    }

    @Test("結果帶著大小與時間")
    func resultsCarrySizeAndDate() async throws {
        try await withService { service, server in
            let when = Date(timeIntervalSince1970: 1_787_458_500)
            server.store.put(Data("0123456789".utf8), forKey: "notes/todo.md", modifiedAt: when)
            let found = try await service.searchItems(matching: "todo", under: "/", limit: 50)
            #expect(found.count == 1)
            #expect(found.first?.size == 10)
            #expect(found.first?.modificationDate == when)
        }
    }

    /// Declared on the protocol so the call is dispatched dynamically. Reached
    /// only through the extension's default otherwise, and the whole point of
    /// the override would be lost silently.
    @Test("透過 protocol 呼叫時走的是 S3 的版本")
    func theOverrideIsReachedThroughTheProtocol() async throws {
        try await withService { service, server in
            seed(server)
            let before = server.store.listingCount
            let anyService: any RemoteFileService = service
            _ = try await anyService.searchItems(matching: "access", under: "/", limit: 50)
            #expect(server.store.listingCount - before == 1)
        }
    }
}
