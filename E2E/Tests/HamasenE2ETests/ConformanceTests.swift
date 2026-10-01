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

/// The same behaviour asked of every protocol, against real servers.
///
/// The File Provider extension treats every service alike, so a difference
/// between them — a rename that overwrites on one server and refuses on
/// another, a name that comes back spelled differently — is a bug in
/// whichever one differs, whatever the unit tests' fakes say.
@Suite("Protocol conformance", .enabled(if: E2E.isAvailable))
struct ConformanceTests {
    /// A connected client and a folder of its own on the server.
    private static func workspace(_ lane: Lane) async throws -> (any RemoteFileService, String) {
        let service = try await LaneClients(lane: lane, viaProxy: false).connected()
        let folder = "/" + E2E.uniqueName("conformance")
        try await service.createDirectory(at: folder)
        return (service, folder)
    }

    private static func cleanUp(_ service: any RemoteFileService, _ folder: String) async {
        try? await service.deleteDirectory(at: folder)
        try? await service.disconnect()
    }

    @Test("上傳與下載的內容一致，部分讀取取得正確範圍", arguments: Lane.allCases)
    func transfersBytesIntact(lane: Lane) async throws {
        let (service, folder) = try await Self.workspace(lane)
        // Sizes chosen at the edges that matter: empty, one byte, one of each
        // client's chunk sizes, and above the multipart thresholds of S3
        // (6 MB here), OneDrive (4 MB) and Dropbox (32 MB).
        let sizes = [0, 1, 4_096, 1_048_577, 7_340_033, 34_000_000]
        for (index, size) in sizes.enumerated() {
            let data = Fixtures.bytes(size, seed: UInt64(index + 1))
            let path = RemotePath.join(folder, "file-\(size).bin")
            let uploaded = try await Fixtures.upload(data, to: path, with: service)
            #expect(try await Fixtures.downloadHash(path, with: service) == uploaded, "\(lane) \(size) bytes")
            #expect(try await service.itemInfo(at: path).size == Int64(size))
            guard size > 0 else { continue }
            for (offset, length) in [(0, min(size, 100)), (size / 2, min(size - size / 2, 65_537)), (size - 1, 1)] {
                let slice = try await service.downloadRange(at: path, offset: Int64(offset), length: length)
                #expect(slice == data.subdata(in: offset..<offset + length), "\(lane) range \(offset)+\(length)")
            }
            let pastEnd = try await service.downloadRange(at: path, offset: Int64(size - 1), length: 10)
            #expect(pastEnd == data.suffix(1), "\(lane) range past the end")
        }
        await Self.cleanUp(service, folder)
    }

    @Test("各種檔名原樣往返", arguments: Lane.allCases)
    func keepsNames(lane: Lane) async throws {
        let (service, folder) = try await Self.workspace(lane)
        let names = ["報告 2026.pdf", "日本語ファイル.txt", "한국어 문서.txt", "emoji 😀.txt",
                     "a b#c%d+e&f=g.txt", "trailing.dots..txt", "UPPER and lower.TXT"]
        for (index, name) in names.enumerated() {
            try await Fixtures.upload(Fixtures.bytes(100 + index, seed: 7), to: RemotePath.join(folder, name), with: service)
        }
        let listed = Set(try await service.listDirectory(at: folder).map(\.name))
        #expect(listed == Set(names.map { $0.precomposedStringWithCanonicalMapping }), "\(lane)")
        for name in names {
            #expect(try await service.itemInfo(at: RemotePath.join(folder, name)).name
                == name.precomposedStringWithCanonicalMapping)
        }
        await Self.cleanUp(service, folder)
    }

    @Test("資料夾、改名、搬移與刪除", arguments: Lane.allCases)
    func managesTree(lane: Lane) async throws {
        let (service, folder) = try await Self.workspace(lane)
        let inner = RemotePath.join(folder, "a")
        let deeper = RemotePath.join(inner, "b")
        try await service.createDirectory(at: inner)
        try await service.createDirectory(at: deeper)
        let file = RemotePath.join(inner, "one.txt")
        let hash = try await Fixtures.upload(Fixtures.bytes(2_000, seed: 3), to: file, with: service)

        let renamed = RemotePath.join(inner, "renamed.txt")
        try await service.moveItem(from: file, to: renamed)
        let moved = RemotePath.join(deeper, "renamed.txt")
        try await service.moveItem(from: renamed, to: moved)
        #expect(try await Fixtures.downloadHash(moved, with: service) == hash)
        await #expect(throws: RemoteFileServiceError.itemNotFound(path: file)) {
            _ = try await service.itemInfo(at: file)
        }

        let renamedFolder = RemotePath.join(folder, "c")
        try await service.moveItem(from: inner, to: renamedFolder)
        #expect(try await Fixtures.downloadHash(RemotePath.join(renamedFolder, "b/renamed.txt"), with: service) == hash)

        try await service.deleteFile(at: RemotePath.join(renamedFolder, "b/renamed.txt"))
        try await Fixtures.upload(Fixtures.bytes(10, seed: 4), to: RemotePath.join(renamedFolder, "b/x.txt"), with: service)
        try await service.deleteDirectory(at: renamedFolder)
        #expect(try await service.listDirectory(at: folder).isEmpty, "\(lane) recursive delete")
        await Self.cleanUp(service, folder)
    }

    /// The extension reports a name already taken as a collision, which is
    /// what lets Finder ask; a server that silently replaces the file instead
    /// loses whatever was there.
    @Test("已存在的名稱回報衝突，兩邊內容都保留", arguments: Lane.allCases)
    func refusesToOverwriteOnMove(lane: Lane) async throws {
        let (service, folder) = try await Self.workspace(lane)
        let first = RemotePath.join(folder, "first.txt")
        let second = RemotePath.join(folder, "second.txt")
        let firstHash = try await Fixtures.upload(Fixtures.bytes(500, seed: 11), to: first, with: service)
        let secondHash = try await Fixtures.upload(Fixtures.bytes(600, seed: 12), to: second, with: service)

        await #expect(throws: RemoteFileServiceError.alreadyExists(path: second), "\(lane) move onto a file") {
            try await service.moveItem(from: first, to: second)
        }
        #expect(try await Fixtures.downloadHash(first, with: service) == firstHash, "\(lane)")
        #expect(try await Fixtures.downloadHash(second, with: service) == secondHash, "\(lane)")

        let directory = RemotePath.join(folder, "dir")
        try await service.createDirectory(at: directory)
        await #expect(throws: RemoteFileServiceError.alreadyExists(path: directory), "\(lane) mkdir twice") {
            try await service.createDirectory(at: directory)
        }
        await Self.cleanUp(service, folder)
    }

    @Test("找不到的項目回報找不到", arguments: Lane.allCases)
    func reportsMissingItems(lane: Lane) async throws {
        let (service, folder) = try await Self.workspace(lane)
        let missing = RemotePath.join(folder, "missing.txt")
        await #expect(throws: RemoteFileServiceError.itemNotFound(path: missing), "\(lane)") {
            _ = try await service.itemInfo(at: missing)
        }
        await #expect(throws: RemoteFileServiceError.self, "\(lane)") {
            try await service.downloadFile(at: missing, to: Fixtures.temporaryURL(), progress: nil)
        }
        await Self.cleanUp(service, folder)
    }

    @Test("覆寫後讀到新內容，版本識別跟著變", arguments: Lane.allCases)
    func overwrites(lane: Lane) async throws {
        let (service, folder) = try await Self.workspace(lane)
        let path = RemotePath.join(folder, "edited.txt")
        try await Fixtures.upload(Fixtures.bytes(1_000, seed: 21), to: path, with: service)
        let before = try await service.itemInfo(at: path)
        // Some servers keep modification times to the second; an edit inside
        // the same second with the same size would otherwise look unchanged.
        // An FTP server without MLSD lists them to the minute, which no wait
        // a test can afford gets past, so there the edit changes the size —
        // the README lists the same-size case as a limitation.
        try await Task.sleep(for: .seconds(1.1))
        let editedSize = (lane.modificationTimePrecision ?? 0) > 1 ? 1_001 : 1_000
        let after = try await Fixtures.upload(Fixtures.bytes(editedSize, seed: 22), to: path, with: service)
        #expect(try await Fixtures.downloadHash(path, with: service) == after)
        #expect(try await service.itemInfo(at: path).contentVersionToken != before.contentVersionToken, "\(lane)")
        let listed = try await service.listDirectory(at: folder)
        #expect(!listed.contains { RemotePath.isTemporaryUpload(name: $0.name) }, "\(lane) shows an upload in flight")
        await Self.cleanUp(service, folder)
    }

    @Test("同一個連線上同時多個傳輸", arguments: Lane.allCases)
    func handlesConcurrentTransfers(lane: Lane) async throws {
        let (service, folder) = try await Self.workspace(lane)
        let hashes = try await withThrowingTaskGroup(of: (String, String).self) { group in
            for index in 0..<8 {
                group.addTask {
                    let path = RemotePath.join(folder, "parallel-\(index).bin")
                    let hash = try await Fixtures.upload(Fixtures.bytes(200_000 + index, seed: UInt64(100 + index)), to: path, with: service)
                    return (path, hash)
                }
            }
            var all: [(String, String)] = []
            for try await result in group { all.append(result) }
            return all
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (path, hash) in hashes {
                group.addTask {
                    let downloaded = try await Fixtures.downloadHash(path, with: service)
                    #expect(downloaded == hash, "\(lane) \(path)")
                }
            }
            try await group.waitForAll()
        }
        await Self.cleanUp(service, folder)
    }

    @Test("搜尋找得到檔名", arguments: Lane.allCases)
    func searches(lane: Lane) async throws {
        let (service, folder) = try await Self.workspace(lane)
        try await service.createDirectory(at: RemotePath.join(folder, "deep"))
        try await Fixtures.upload(Data("x".utf8), to: RemotePath.join(folder, "deep/quarterly-budget.xlsx"), with: service)
        try await Fixtures.upload(Data("y".utf8), to: RemotePath.join(folder, "notes.txt"), with: service)
        let found = try await service.searchItems(matching: "budget", under: folder, limit: 10)
        #expect(found.map(\.name) == ["quarterly-budget.xlsx"], "\(lane)")
        await Self.cleanUp(service, folder)
    }

    @Test("斷線後重新連線", arguments: Lane.allCases)
    func reconnects(lane: Lane) async throws {
        let (service, folder) = try await Self.workspace(lane)
        try await service.disconnect()
        let fresh = try await LaneClients(lane: lane, viaProxy: false).connected()
        #expect(try await fresh.listDirectory(at: folder).isEmpty)
        await Self.cleanUp(fresh, folder)
    }

    @Test("密碼錯誤時回報認證失敗", arguments: Lane.allCases.filter(\.hasPassword))
    func rejectsWrongPasswords(lane: Lane) async throws {
        let clients = LaneClients(lane: lane, viaProxy: false)
        clients.credentials.currentPassword = "wrong-password"
        let service = try await clients.make()
        await #expect(throws: RemoteFileServiceError.authenticationFailed, "\(lane)") {
            try await service.connect()
        }
    }
}
