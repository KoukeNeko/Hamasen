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

/// End-to-end tests for FTPFileService against the in-process FTP server.
///
/// This is where the control connection, the passive data connection and the
/// two-part end of a transfer are exercised: none of them can be checked by
/// reading a reply on its own.
@Suite("FTPFileService")
struct FTPFileServiceTests {
    private static func makeConnectedService(
        advertisingMLSD: Bool = true,
        advertisingMLST: Bool = true,
        remotePath: String = "/",
        connectTimeoutSeconds: Int = AppSettings.defaultConnectTimeoutSeconds
    ) async throws -> (FTPFileService, TestFTPServer) {
        let server = try await TestFTPServer.start(
            advertisingMLSD: advertisingMLSD,
            advertisingMLST: advertisingMLST
        )
        let service = FTPFileService(
            config: ServerConfig(
                name: "測試伺服器",
                transferProtocol: .ftp,
                host: "127.0.0.1",
                port: server.port,
                username: TestFTPServer.username,
                remotePath: remotePath
            ),
            credentials: .password(TestFTPServer.password),
            connectTimeoutSeconds: connectTimeoutSeconds
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
        let (service, server) = try await Self.makeConnectedService(advertisingMLSD: false, advertisingMLST: false)
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

    /// What the fix to the ranged read was for, made observable: the server
    /// writes in pieces, so how much it got out before the client stopped
    /// reading says whether the client stopped at all. Reading to the end and
    /// discarding the rest would leave this equal to the file.
    @Test("區間讀取會提前中止，不會把整個檔案收完")
    func stopsReadingOnceItHasTheRange() async throws {
        let (service, server) = try await Self.makeConnectedService()
        var contents = Data()
        while contents.count < 4_000_000 {
            contents.append(contentsOf: Array("0123456789".utf8))
        }
        try contents.write(to: server.rootDirectory.appendingPathComponent("large.bin"))

        let range = try await service.downloadRange(at: "/large.bin", offset: 0, length: 10)
        #expect(range.count == 10)
        #expect(
            server.bytesSentInLastDownload < contents.count,
            "sent \(server.bytesSentInLastDownload) of \(contents.count) bytes, so the read did not stop early"
        )

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

    /// The actor is reentrant at every await, so without a lock of its own
    /// two operations interleave their EPSV/MLSD/RETR sequences on the one
    /// control connection and each reads the other's reply.
    @Test("同時進行的操作不會互相干擾")
    func concurrentOperationsStayIndependent() async throws {
        let (service, server) = try await Self.makeConnectedService()
        try FileManager.default.createDirectory(
            at: server.rootDirectory.appendingPathComponent("docs"), withIntermediateDirectories: false
        )
        for index in 0..<5 {
            try Self.write("file \(index)", to: "docs/f\(index).txt", in: server)
        }
        var big = Data()
        while big.count < 1_000_000 { big.append(contentsOf: Array("0123456789".utf8)) }
        try big.write(to: server.rootDirectory.appendingPathComponent("big.bin"))
        try Self.write("hello", to: "notes.txt", in: server)

        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftp-concurrent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: localURL) }

        enum Outcome: Sendable { case names([String]), info(Int64), downloaded }
        var outcomes: [Outcome] = []
        await withTaskGroup(of: Outcome?.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    (try? await service.listDirectory(at: "/docs")).map { .names($0.map(\.name).sorted()) }
                }
            }
            group.addTask {
                (try? await service.downloadFile(at: "/big.bin", to: localURL)).map { .downloaded }
            }
            group.addTask {
                (try? await service.itemInfo(at: "/notes.txt")).map { .info($0.size) }
            }
            for await outcome in group { if let outcome { outcomes.append(outcome) } }
        }

        #expect(outcomes.count == 6)
        let expectedNames = (0..<5).map { "f\($0).txt" }
        for case .names(let names) in outcomes { #expect(names == expectedNames) }
        #expect(outcomes.contains { if case .info(5) = $0 { true } else { false } })
        #expect(try Data(contentsOf: localURL) == big)

        try await Self.tearDown(service, server)
    }

    // MARK: - Session integrity

    /// RFC 3659: a server that lists MLST supports MLSD, and most list only
    /// MLST. The times show which listing was read: LIST stops at the minute.
    @Test("FEAT 只列 MLST 時也用 MLSD 列出目錄")
    func mlstImpliesMachineListing() async throws {
        let (service, server) = try await Self.makeConnectedService(advertisingMLSD: false, advertisingMLST: true)
        try Self.write("hello", to: "notes.txt", in: server)
        let moment = Date(timeIntervalSince1970: 1_767_225_637)  // 37 seconds past the minute
        try FileManager.default.setAttributes(
            [.modificationDate: moment],
            ofItemAtPath: server.rootDirectory.appendingPathComponent("notes.txt").path
        )

        let listed = try #require(try await service.listDirectory(at: "/").first)
        #expect(listed.modificationDate == moment)
        #expect(try await service.itemInfo(at: "/notes.txt").modificationDate == moment)
        try await Self.tearDown(service, server)
    }

    // MARK: - Data connection order

    /// vsftpd sends 150 only after accepting the data connection, so a client
    /// that waits for it before connecting stalls until the timeout. Both
    /// orders of the server have to work for every kind of transfer.
    @Test("各種傳輸在伺服器先接受資料連線才回 150 時也能運作", arguments: [false, true], [true, false])
    func transfersWorkWhenTheServerRepliesAfterAcceptingData(
        repliesAfterDataAccept: Bool, machineListing: Bool
    ) async throws {
        let (service, server) = try await Self.makeConnectedService(
            advertisingMLSD: machineListing, advertisingMLST: machineListing, connectTimeoutSeconds: 5
        )
        server.behavior.repliesAfterDataAccept = repliesAfterDataAccept
        let contents = try Self.makeLargeFile(named: "big.bin", in: server, bytes: 300_000)

        #expect(try await service.listDirectory(at: "/").map(\.name) == ["big.bin"])
        #expect(try await service.itemInfo(at: "/big.bin").size == Int64(contents.count))

        let downloaded = Self.temporaryURL("order-down")
        defer { try? FileManager.default.removeItem(at: downloaded) }
        try await service.downloadFile(at: "/big.bin", to: downloaded)
        #expect(try Data(contentsOf: downloaded) == contents)

        let range = try await service.downloadRange(at: "/big.bin", offset: 1_000, length: 4)
        #expect(String(decoding: range, as: UTF8.self) == "0123")

        try await service.uploadFile(from: downloaded, to: "/copy.bin")
        #expect(try Data(contentsOf: server.rootDirectory.appendingPathComponent("copy.bin")) == contents)

        // A refused transfer leaves the data connection it opened unused.
        await #expect(throws: RemoteFileServiceError.itemNotFound(path: "/nothing.bin")) {
            try await service.downloadFile(at: "/nothing.bin", to: downloaded)
        }
        #expect(try await service.listDirectory(at: "/").count == 2)
        try await Self.tearDown(service, server)
    }

    private static func makeLargeFile(named name: String, in server: TestFTPServer, bytes: Int) throws -> Data {
        var contents = Data()
        while contents.count < bytes { contents.append(contentsOf: Array("0123456789".utf8)) }
        try contents.write(to: server.rootDirectory.appendingPathComponent(name))
        return contents
    }

    private static func temporaryURL(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ftp-\(label)-\(UUID().uuidString)")
    }

    /// Whatever the control connection has left unread would be taken for the
    /// reply to the next command, so a session that failed mid-transfer has
    /// to be replaced, not reused.
    @Test("取消下載後會放棄這條連線，重新連線後正常", arguments: [false, true])
    func cancellingADownloadDropsTheSession(repliesAfterDataAccept: Bool) async throws {
        let (service, server) = try await Self.makeConnectedService()
        server.behavior.repliesAfterDataAccept = repliesAfterDataAccept
        _ = try Self.makeLargeFile(named: "big.bin", in: server, bytes: 2_000_000)
        try Self.write("hello", to: "notes.txt", in: server)
        server.behavior.chunkDelayMilliseconds = 20
        let localURL = Self.temporaryURL("cancel")
        defer { try? FileManager.default.removeItem(at: localURL) }

        let download = Task {
            try await service.downloadFile(at: "/big.bin", to: localURL) { _ in }
        }
        // Cancelled once bytes are moving, not before the transfer starts.
        while !FileManager.default.fileExists(atPath: localURL.path)
                || ((try? Data(contentsOf: localURL).count) ?? 0) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        download.cancel()
        await #expect(throws: CancellationError.self) { try await download.value }

        #expect(await service.isConnected == false)
        await #expect(throws: RemoteFileServiceError.notConnected) {
            try await service.listDirectory(at: "/")
        }

        server.behavior.chunkDelayMilliseconds = 0
        try await service.connect()
        #expect(try await service.itemInfo(at: "/notes.txt").size == 5)
        try await Self.tearDown(service, server)
    }

    @Test("下載與上傳會回報累計的位元組數")
    func reportsTransferProgress() async throws {
        let (service, server) = try await Self.makeConnectedService()
        let contents = try Self.makeLargeFile(named: "big.bin", in: server, bytes: 500_000)

        let downloaded = ProgressLog()
        let localURL = Self.temporaryURL("progress")
        defer { try? FileManager.default.removeItem(at: localURL) }
        try await service.downloadFile(at: "/big.bin", to: localURL) { downloaded.record($0) }
        #expect(downloaded.values.last == Int64(contents.count))
        #expect(downloaded.values == downloaded.values.sorted())

        let uploaded = ProgressLog()
        try await service.uploadFile(from: localURL, to: "/copy.bin") { uploaded.record($0) }
        #expect(uploaded.values.last == Int64(contents.count))
        #expect(uploaded.values == uploaded.values.sorted())

        try await Self.tearDown(service, server)
    }

    @Test("伺服器不回覆指令時逾時並放棄連線")
    func timesOutWhenTheServerStopsAnswering() async throws {
        let (service, server) = try await Self.makeConnectedService(connectTimeoutSeconds: 1)
        server.behavior.unresponsiveCommands = ["EPSV"]

        do {
            _ = try await service.listDirectory(at: "/")
            Issue.record("expected the listing to time out")
        } catch let error as RemoteFileServiceError {
            guard case .connectionFailed = error else {
                Issue.record("expected connectionFailed, got \(error)")
                return
            }
        }
        #expect(await service.isConnected == false)
        try await server.stop()
    }

    @Test("資料連線停止傳輸時逾時並放棄連線")
    func timesOutWhenTheDataConnectionGoesQuiet() async throws {
        let (service, server) = try await Self.makeConnectedService(connectTimeoutSeconds: 1)
        try Self.write("hello", to: "notes.txt", in: server)
        server.behavior.stallsDataTransfers = true
        let localURL = Self.temporaryURL("stall")
        defer { try? FileManager.default.removeItem(at: localURL) }

        do {
            try await service.downloadFile(at: "/notes.txt", to: localURL)
            Issue.record("expected the download to time out")
        } catch let error as RemoteFileServiceError {
            guard case .connectionFailed = error else {
                Issue.record("expected connectionFailed, got \(error)")
                return
            }
        }
        #expect(await service.isConnected == false)
        try await server.stop()
    }

    /// The range is already in hand when the closing reply fails to come, so
    /// it is returned; only the session, whose reply is now owed, is given up.
    @Test("區間讀取遇到不回覆的伺服器不會卡住")
    func rangeReadDoesNotHangOnASilentServer() async throws {
        let (service, server) = try await Self.makeConnectedService(connectTimeoutSeconds: 1)
        _ = try Self.makeLargeFile(named: "big.bin", in: server, bytes: 2_000_000)
        server.behavior.withholdsCompletionReply = true

        let range = try await service.downloadRange(at: "/big.bin", offset: 0, length: 10)
        #expect(String(decoding: range, as: UTF8.self) == "0123456789")
        #expect(await service.isConnected == false)
        try await server.stop()
    }

    // MARK: - Atomic upload

    @Test("上傳會覆蓋既有檔案且不留下暫存檔")
    func uploadReplacesAnExistingFile() async throws {
        let (service, server) = try await Self.makeConnectedService()
        try Self.write("old contents", to: "target.txt", in: server)
        let localURL = Self.temporaryURL("replace")
        try Data("new".utf8).write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }

        try await service.uploadFile(from: localURL, to: "/target.txt")

        let names = try FileManager.default.contentsOfDirectory(atPath: server.rootDirectory.path)
        #expect(names == ["target.txt"])
        #expect(try String(contentsOf: server.rootDirectory.appendingPathComponent("target.txt"), encoding: .utf8) == "new")
        try await Self.tearDown(service, server)
    }

    @Test("上傳失敗時移除暫存檔")
    func failedUploadRemovesTheTemporaryFile() async throws {
        let (service, server) = try await Self.makeConnectedService()
        server.behavior.rejectsRename = true
        let localURL = Self.temporaryURL("failed")
        try Data("new".utf8).write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }

        await #expect(throws: RemoteFileServiceError.self) {
            try await service.uploadFile(from: localURL, to: "/target.txt")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: server.rootDirectory.path).isEmpty)
        #expect(await service.isConnected)
        try await Self.tearDown(service, server)
    }

    @Test("列出目錄時略過進行中的上傳暫存檔")
    func listingHidesTemporaryUploads() async throws {
        let (service, server) = try await Self.makeConnectedService()
        try Self.write("visible", to: "real.txt", in: server)
        let temporaryName = RemotePath.name(of: RemotePath.temporaryUploadPath(for: "/real.txt"))
        try Self.write("partial", to: temporaryName, in: server)

        #expect(try await service.listDirectory(at: "/").map(\.name) == ["real.txt"])
        try await Self.tearDown(service, server)
    }

    /// vsftpd, like most servers, leaves names that start with a dot out of
    /// LIST unless asked with -a. A folder holding one — a .gitignore, or an
    /// upload cut off with its connection — then looked empty and could not
    /// be deleted.
    @Test("LIST 預設隱藏點開頭的名稱時，仍會列出並能刪除含有它們的目錄")
    func listsAndDeletesDotFilesOnServersThatHideThem() async throws {
        let (service, server) = try await Self.makeConnectedService(advertisingMLSD: false, advertisingMLST: false)
        server.behavior.hidesDotFiles = true
        let folder = server.rootDirectory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("x".utf8).write(to: folder.appendingPathComponent(".gitignore"))
        let temporaryName = RemotePath.name(of: RemotePath.temporaryUploadPath(for: "/project/report.txt"))
        try Data("partial".utf8).write(to: folder.appendingPathComponent(temporaryName))

        #expect(try await service.listDirectory(at: "/project").map(\.name) == [".gitignore"])
        #expect(try await service.itemInfo(at: "/project/.gitignore").size == 1)
        try await service.deleteDirectory(at: "/project")
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        try await Self.tearDown(service, server)
    }

    @Test("伺服器不接受 LIST 的選項時改用不帶選項的 LIST")
    func listsWithoutOptionsWhenTheServerRefusesThem() async throws {
        let (service, server) = try await Self.makeConnectedService(advertisingMLSD: false, advertisingMLST: false)
        server.behavior.refusesListOptions = true
        try Self.write("hello", to: "notes.txt", in: server)

        #expect(try await service.listDirectory(at: "/").map(\.name) == ["notes.txt"])
        #expect(try await service.listDirectory(at: "/").map(\.name) == ["notes.txt"])
        #expect(server.listCommands == ["LIST -a /", "LIST /", "LIST /"])
        await #expect(throws: RemoteFileServiceError.itemNotFound(path: "/missing")) {
            try await service.listDirectory(at: "/missing")
        }
        #expect(await service.isConnected)
        try await Self.tearDown(service, server)
    }

    /// A server that reads "-a" as part of the name may call that name
    /// missing with a 450. Without MLSD every listing went through LIST -a,
    /// so every one of them failed.
    @Test("LIST -a 被以 4xx 拒絕時改用不帶選項的 LIST，之後不再嘗試")
    func listsWithoutOptionsWhenTheServerRefusesThemTransiently() async throws {
        let (service, server) = try await Self.makeConnectedService(advertisingMLSD: false, advertisingMLST: false)
        server.behavior.refusesListOptions = true
        server.behavior.missingListingAnswer = .transientFailure
        try Self.write("hello", to: "notes.txt", in: server)

        #expect(try await service.listDirectory(at: "/").map(\.name) == ["notes.txt"])
        #expect(try await service.listDirectory(at: "/").map(\.name) == ["notes.txt"])
        #expect(server.listCommands == ["LIST -a /", "LIST /", "LIST /"])
        try await Self.tearDown(service, server)
    }

    /// One that lists "-a /path" as a pattern matching nothing answers 226
    /// with no entries. Every folder then looked empty, and the extension
    /// reported everything in it as deleted.
    @Test("LIST -a 列出空清單而 LIST 列得出項目時改用不帶選項的 LIST")
    func listsWithoutOptionsWhenTheyListNothing() async throws {
        let (service, server) = try await Self.makeConnectedService(advertisingMLSD: false, advertisingMLST: false)
        server.behavior.refusesListOptions = true
        server.behavior.missingListingAnswer = .emptyListing
        try Self.write("hello", to: "notes.txt", in: server)

        #expect(try await service.listDirectory(at: "/").map(\.name) == ["notes.txt"])
        #expect(try await service.listDirectory(at: "/").map(\.name) == ["notes.txt"])
        #expect(server.listCommands == ["LIST -a /", "LIST /", "LIST /"])
        try await Self.tearDown(service, server)
    }

    /// A server that supports -a can still turn one LIST -a away. A plain
    /// LIST that then lists an empty folder says nothing about the option;
    /// settling on it would hide dot-files from then on, stranded uploads
    /// among them, and leave their folders impossible to delete.
    @Test("LIST -a 一時失敗而空目錄的 LIST 成功時，不就此停用 -a")
    func keepsTheOptionAfterARefusalOverAnEmptyFolder() async throws {
        let (service, server) = try await Self.makeConnectedService(advertisingMLSD: false, advertisingMLST: false)
        server.behavior.hidesDotFiles = true
        server.behavior.listOptionFailures = 1
        try FileManager.default.createDirectory(
            at: server.rootDirectory.appendingPathComponent("empty"), withIntermediateDirectories: false
        )
        let project = server.rootDirectory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        try Data("x".utf8).write(to: project.appendingPathComponent(".gitignore"))

        #expect(try await service.listDirectory(at: "/empty").isEmpty)
        #expect(try await service.listDirectory(at: "/project").map(\.name) == [".gitignore"])
        try await Self.tearDown(service, server)
    }

    /// An empty answer to LIST -a is checked against a plain LIST only until
    /// the option has listed something; after that an empty folder is empty.
    @Test("確認伺服器接受 LIST -a 後，空目錄只列一次")
    func listsAnEmptyFolderOnceTheOptionIsKnownToWork() async throws {
        let (service, server) = try await Self.makeConnectedService(advertisingMLSD: false, advertisingMLST: false)
        server.behavior.hidesDotFiles = true
        try Self.write("hello", to: "notes.txt", in: server)
        try FileManager.default.createDirectory(
            at: server.rootDirectory.appendingPathComponent("empty"), withIntermediateDirectories: false
        )

        #expect(try await service.listDirectory(at: "/").map(\.name).sorted() == ["empty", "notes.txt"])
        #expect(try await service.listDirectory(at: "/empty").isEmpty)
        #expect(server.listCommands == ["LIST -a /", "LIST -a /empty"])
        try await Self.tearDown(service, server)
    }

    // MARK: - Error classification

    /// A server's 550 text is its own wording, often not English, so a missing
    /// item cannot be recognised by what the message says.
    @Test("550 的文字不是英文時仍能分辨不存在與沒有權限")
    func classifiesRefusalsWithoutReadingTheText() async throws {
        let (service, server) = try await Self.makeConnectedService(advertisingMLST: false)
        server.behavior.genericFailureText = "Could not get file size."
        try Self.write("secret", to: "locked.txt", in: server)
        server.behavior.deniedNames = ["locked.txt"]
        let localURL = Self.temporaryURL("classify")
        defer { try? FileManager.default.removeItem(at: localURL) }

        await #expect(throws: RemoteFileServiceError.itemNotFound(path: "/missing.txt")) {
            try await service.itemInfo(at: "/missing.txt")
        }
        await #expect(throws: RemoteFileServiceError.itemNotFound(path: "/missing.txt")) {
            try await service.deleteFile(at: "/missing.txt")
        }
        await #expect(throws: RemoteFileServiceError.itemNotFound(path: "/missing.txt")) {
            try await service.downloadFile(at: "/missing.txt", to: localURL)
        }
        await #expect(throws: RemoteFileServiceError.itemNotFound(path: "/missing-dir")) {
            _ = try await service.listDirectory(at: "/missing-dir")
        }

        do {
            try await service.deleteFile(at: "/locked.txt")
            Issue.record("expected a refusal")
        } catch let error as RemoteFileServiceError {
            guard case .permissionDenied(_, let path) = error else {
                Issue.record("expected permissionDenied, got \(error)")
                return
            }
            #expect(path == "/locked.txt")
        }
        // Refusals are replies, so the session is still in step.
        #expect(await service.isConnected)
        try await Self.tearDown(service, server)
    }

    @Test("STOR 被拒絕時回報沒有權限")
    func refusedUploadIsPermissionDenied() async throws {
        let (service, server) = try await Self.makeConnectedService()
        server.behavior.storeRefusal = (553, "Requested action not taken.")
        let localURL = Self.temporaryURL("denied")
        try Data("x".utf8).write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }

        do {
            try await service.uploadFile(from: localURL, to: "/target.txt")
            Issue.record("expected a refusal")
        } catch let error as RemoteFileServiceError {
            guard case .permissionDenied = error else {
                Issue.record("expected permissionDenied, got \(error)")
                return
            }
        }
        try await Self.tearDown(service, server)
    }

    @Test("建立已存在的目錄與移到已存在的名稱回報已存在")
    func reportsAnExistingDestination() async throws {
        let (service, server) = try await Self.makeConnectedService()
        try await service.createDirectory(at: "/dir")
        try Self.write("a", to: "a.txt", in: server)
        try Self.write("b", to: "b.txt", in: server)

        await #expect(throws: RemoteFileServiceError.alreadyExists(path: "/dir")) {
            try await service.createDirectory(at: "/dir")
        }
        await #expect(throws: RemoteFileServiceError.alreadyExists(path: "/b.txt")) {
            try await service.moveItem(from: "/a.txt", to: "/b.txt")
        }
        try await Self.tearDown(service, server)
    }

    // MARK: - Listing and lookup agree

    /// The item version is size plus time to the second. LIST gives minutes,
    /// MDTM gives seconds; a lookup that asked MDTM would version the same
    /// file differently from the listing and have it fetched again.
    @Test("itemInfo 與列表對同一項目給出相同版本", arguments: [
        (true, true), (true, false), (false, true), (false, false),
    ])
    func lookupAgreesWithTheListing(advertisingMLSD: Bool, advertisingMLST: Bool) async throws {
        let (service, server) = try await Self.makeConnectedService(
            advertisingMLSD: advertisingMLSD, advertisingMLST: advertisingMLST
        )
        try Self.write("hello", to: "notes.txt", in: server)
        try FileManager.default.createDirectory(
            at: server.rootDirectory.appendingPathComponent("docs"), withIntermediateDirectories: false
        )
        let moment = Date(timeIntervalSinceNow: -86_400 * 3 + 37)
        for name in ["notes.txt", "docs"] {
            try FileManager.default.setAttributes(
                [.modificationDate: moment], ofItemAtPath: server.rootDirectory.appendingPathComponent(name).path
            )
        }

        for item in try await service.listDirectory(at: "/") {
            let info = try await service.itemInfo(at: item.path)
            #expect(info.kind == item.kind)
            #expect(info.contentVersionToken == item.contentVersionToken, "\(item.name)")
        }
        #expect(try await service.itemInfo(at: "/").kind == .directory)
        try await Self.tearDown(service, server)
    }

    @Test("根目錄與掛載根目錄的資訊可以讀取")
    func lookupWorksBelowAMountRoot() async throws {
        let server = try await TestFTPServer.start()
        let base = server.rootDirectory.appendingPathComponent("base")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        try Data("inside".utf8).write(to: base.appendingPathComponent("inside.txt"))
        let service = FTPFileService(
            config: ServerConfig(
                name: "測試伺服器", transferProtocol: .ftp, host: "127.0.0.1", port: server.port,
                username: TestFTPServer.username, remotePath: "/base"
            ),
            credentials: .password(TestFTPServer.password)
        )
        try await service.connect()

        #expect(try await service.itemInfo(at: "/").kind == .directory)
        #expect(try await service.itemInfo(at: "/inside.txt").size == 6)
        try await Self.tearDown(service, server)
    }

    // MARK: - Symbolic links

    @Test("符號連結呈現為指向的型別，列表與 itemInfo 一致", arguments: [true, false])
    func reportsALinkAsItsTarget(advertisingMLSD: Bool) async throws {
        let (service, server) = try await Self.makeConnectedService(advertisingMLSD: advertisingMLSD, advertisingMLST: advertisingMLSD)
        let target = server.rootDirectory.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try Self.write("hello", to: "file.txt", in: server)
        try FileManager.default.createSymbolicLink(
            atPath: server.rootDirectory.appendingPathComponent("dirlink").path, withDestinationPath: target.path
        )
        try FileManager.default.createSymbolicLink(
            atPath: server.rootDirectory.appendingPathComponent("filelink").path,
            withDestinationPath: server.rootDirectory.appendingPathComponent("file.txt").path
        )

        let items = try await service.listDirectory(at: "/")
        #expect(items.first { $0.name == "dirlink" }?.kind == .directory)
        #expect(items.first { $0.name == "filelink" }?.kind == .file)
        for name in ["dirlink", "filelink"] {
            let listed = try #require(items.first { $0.name == name })
            let info = try await service.itemInfo(at: "/\(name)")
            #expect(info.kind == listed.kind)
            #expect(info.contentVersionToken == listed.contentVersionToken)
        }
        try await Self.tearDown(service, server)
    }

    /// The listing reports a link to a folder as a folder, so a delete that
    /// believed it would walk the link and empty the folder it points at.
    @Test("刪除指向目錄的符號連結不會刪到目標內容", arguments: [true, false])
    func deletingALinkLeavesItsTargetAlone(advertisingMLSD: Bool) async throws {
        let (service, server) = try await Self.makeConnectedService(advertisingMLSD: advertisingMLSD, advertisingMLST: advertisingMLSD)
        let target = server.rootDirectory.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try Data("precious".utf8).write(to: target.appendingPathComponent("keep.txt"))
        let link = server.rootDirectory.appendingPathComponent("dirlink")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)

        try await service.deleteDirectory(at: "/dirlink")

        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil)
        #expect(try String(contentsOf: target.appendingPathComponent("keep.txt"), encoding: .utf8) == "precious")
        try await Self.tearDown(service, server)
    }

    @Test("刪除目錄時，內部的符號連結只移除連結本身", arguments: [true, false])
    func deletingADirectoryDoesNotFollowLinksInside(advertisingMLSD: Bool) async throws {
        let (service, server) = try await Self.makeConnectedService(advertisingMLSD: advertisingMLSD, advertisingMLST: advertisingMLSD)
        let target = server.rootDirectory.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try Data("precious".utf8).write(to: target.appendingPathComponent("keep.txt"))
        let doomed = server.rootDirectory.appendingPathComponent("doomed")
        try FileManager.default.createDirectory(at: doomed, withIntermediateDirectories: false)
        try Data("x".utf8).write(to: doomed.appendingPathComponent("plain.txt"))
        try FileManager.default.createSymbolicLink(
            atPath: doomed.appendingPathComponent("inner-link").path, withDestinationPath: target.path
        )

        try await service.deleteDirectory(at: "/doomed")

        #expect(!FileManager.default.fileExists(atPath: doomed.path))
        #expect(try String(contentsOf: target.appendingPathComponent("keep.txt"), encoding: .utf8) == "precious")
        try await Self.tearDown(service, server)
    }

    // MARK: - Command injection

    @Test("路徑含換行時拒絕送出指令")
    func rejectsPathsWithLineBreaks() async throws {
        let (service, server) = try await Self.makeConnectedService()
        try Self.write("keep", to: "victim.txt", in: server)

        for path in ["/a\r\nDELE /victim.txt", "/a\nDELE /victim.txt"] {
            await #expect(throws: RemoteFileServiceError.self) {
                try await service.deleteFile(at: path)
            }
        }
        #expect(FileManager.default.fileExists(atPath: server.rootDirectory.appendingPathComponent("victim.txt").path))
        // Refused before anything was sent, so the session is untouched.
        #expect(try await service.listDirectory(at: "/").map(\.name) == ["victim.txt"])
        try await Self.tearDown(service, server)
    }
}

/// Collects progress reports, which arrive on the data connection's thread.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int64] = []

    var values: [Int64] { lock.withLock { recorded } }

    func record(_ total: Int64) {
        lock.withLock { recorded.append(total) }
    }
}
