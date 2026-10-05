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

/// An in-memory Drive: items by ID with parents, duplicate names allowed,
/// Google documents that can only be exported, shortcuts, trash, resumable
/// uploads, and rate limits reported as 403.
final class FakeDrive: @unchecked Sendable {
    struct File {
        let id: String
        var name: String
        var mimeType: String
        var parents: [String]
        var data = Data()
        var created: String = "2026-01-01T00:00:00Z"
        var trashed = false
        var version = 1
        var shortcutTarget: (id: String, mimeType: String)?
    }

    private let lock = NSLock()
    private var files: [String: File] = [:]
    private var uploads: [String: (fileID: String?, metadata: [String: Any])] = [:]
    let tokens = StubTokenIssuer()
    /// Answers this many listings with a rate-limit 403 before serving them.
    var rateLimitedListings = 0

    init() {
        files["root-id"] = File(id: "root-id", name: "我的雲端硬碟", mimeType: GoogleDriveFileService.folderType, parents: [])
    }

    @discardableResult
    func add(
        _ name: String, in parent: String = "root-id", mimeType: String = "application/octet-stream",
        data: Data = Data(), id: String = UUID().uuidString, created: String = "2026-01-01T00:00:00Z"
    ) -> String {
        lock.withLock {
            files[id] = File(id: id, name: name, mimeType: mimeType, parents: [parent], data: data, created: created)
        }
        return id
    }

    func addShortcut(_ name: String, to target: String, in parent: String = "root-id") {
        lock.withLock {
            let targetType = files[target]!.mimeType
            var file = File(id: UUID().uuidString, name: name, mimeType: GoogleDriveFileService.shortcutType, parents: [parent])
            file.shortcutTarget = (target, targetType)
            files[file.id] = file
        }
    }

    func file(_ id: String) -> File? { lock.withLock { files[id] } }
    func named(_ name: String) -> [File] { lock.withLock { files.values.filter { $0.name == name } } }

    func session() -> URLSession {
        StubURLProtocol.session { [self] request in handle(request) }
    }

    private func handle(_ request: StubRequest) -> StubResponse {
        if tokens.isTokenRequest(request) { return tokens.handle(request) }
        guard tokens.accepts(request) else {
            return .json(["error": ["code": 401, "message": "Invalid Credentials"]], status: 401)
        }
        return lock.withLock { route(request) }
    }

    private func notFound(_ id: String) -> StubResponse {
        .json(["error": ["code": 404, "message": "File not found: \(id)", "errors": [["reason": "notFound"]]]], status: 404)
    }

    private func json(_ file: File) -> [String: Any] {
        var object: [String: Any] = [
            "id": file.id, "name": file.name, "mimeType": file.mimeType,
            "modifiedTime": "2026-09-30T12:00:00.000Z", "createdTime": file.created,
            "version": String(file.version), "capabilities": ["canEdit": true],
        ]
        if !file.mimeType.hasPrefix("application/vnd.google-apps.") {
            object["size"] = String(file.data.count)
            object["md5Checksum"] = "md5-\(file.data.count)-\(file.version)"
        }
        if let target = file.shortcutTarget {
            object["shortcutDetails"] = ["targetId": target.id, "targetMimeType": target.mimeType]
        }
        return object
    }

    private func route(_ request: StubRequest) -> StubResponse {
        let path = request.url.path
        if path == "/drive/v3/about" {
            return .json(["user": ["emailAddress": "someone@example.com"]])
        }
        if path.hasPrefix("/upload/drive/v3/files") {
            return upload(request)
        }
        guard path.hasPrefix("/drive/v3/files") else { return .status(404) }
        let rest = path.dropFirst("/drive/v3/files".count).split(separator: "/").map(String.init)

        if rest.isEmpty, request.method == "GET" {
            if rateLimitedListings > 0 {
                rateLimitedListings -= 1
                return .json(["error": ["code": 403, "message": "Rate", "errors": [["reason": "userRateLimitExceeded"]]]], status: 403)
            }
            let query = request.query("q") ?? ""
            let parent = query.components(separatedBy: "'")[1]
            let children = files.values.filter { $0.parents.contains(parent == "root" ? "root-id" : parent) && !$0.trashed }
            return .json(["files": children.sorted { $0.id < $1.id }.map(json)])
        }
        if rest.isEmpty, request.method == "POST" {
            let body = request.json
            let id = UUID().uuidString
            files[id] = File(
                id: id, name: body["name"] as? String ?? "", mimeType: body["mimeType"] as? String ?? "",
                parents: body["parents"] as? [String] ?? [])
            return .json(["id": id])
        }
        let id = rest[0] == "root" ? "root-id" : rest[0]
        guard var file = files[id], !file.trashed || request.method == "PATCH" else { return notFound(id) }
        if rest.count == 2, rest[1] == "export" {
            return StubResponse(status: 200, body: Data("EXPORT:\(file.name):\(request.query("mimeType") ?? "")".utf8))
        }
        switch request.method {
        case "GET" where request.query("alt") == "media":
            if let range = request.header("Range"), let bounds = FakeDropbox.bounds(range, size: file.data.count) {
                return StubResponse(status: 206, body: file.data.subdata(in: bounds))
            }
            return StubResponse(status: 200, body: file.data)
        case "GET":
            return .json(json(file))
        case "PATCH":
            let body = request.json
            if let name = body["name"] as? String { file.name = name }
            if let trashed = body["trashed"] as? Bool { file.trashed = trashed }
            if let added = request.query("addParents") {
                file.parents.removeAll { $0 == request.query("removeParents") }
                file.parents.append(added)
            }
            files[id] = file
            return .json(["id": id])
        default:
            return .status(400)
        }
    }

    private func upload(_ request: StubRequest) -> StubResponse {
        if request.method == "PUT", let session = request.query("upload_id"), let pending = uploads[session] {
            uploads[session] = nil
            if let fileID = pending.fileID {
                files[fileID]?.data = request.body
                files[fileID]?.version += 1
                return .json(["id": fileID])
            }
            let id = UUID().uuidString
            files[id] = File(
                id: id, name: pending.metadata["name"] as? String ?? "", mimeType: "application/octet-stream",
                parents: pending.metadata["parents"] as? [String] ?? [], data: request.body)
            return .json(["id": id])
        }
        guard request.query("uploadType") == "resumable" else { return .status(400) }
        let session = UUID().uuidString
        let parts = request.url.path.split(separator: "/")
        let fileID = parts.count > 4 ? String(parts[4]) : nil
        uploads[session] = (fileID, request.json)
        return StubResponse(
            status: 200,
            headers: ["Location": "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&upload_id=\(session)"])
    }
}

@Suite("GoogleDriveFileService")
struct GoogleDriveFileServiceTests {
    private static func service(
        _ fake: FakeDrive, remotePath: String = "/", token: OAuthToken = CloudFixtures.token(provider: .google)
    ) throws -> GoogleDriveFileService {
        try GoogleDriveFileService(
            config: CloudFixtures.config(.googleDrive, remotePath: remotePath),
            credentials: .oauth(token),
            urlSession: fake.session(),
            keychain: CloudFixtures.keychain)
    }

    @Test("以路徑逐層解析資料夾")
    func resolvesPaths() async throws {
        let fake = FakeDrive()
        let photos = fake.add("照片", mimeType: GoogleDriveFileService.folderType)
        fake.add("2026.jpg", in: photos, data: Data("jpeg".utf8))
        let service = try Self.service(fake)
        try await service.connect()
        #expect(try await service.listDirectory(at: "/").map(\.name) == ["照片"])
        let info = try await service.itemInfo(at: "/照片/2026.jpg")
        #expect(info.size == 4)
        #expect(info.kind == .file)
    }

    @Test("同名項目最舊的保留原名，其餘加上 ID")
    func disambiguatesDuplicateNames() async throws {
        let fake = FakeDrive()
        fake.add("report.pdf", data: Data("old".utf8), id: "AAAAAAAAold", created: "2025-01-01T00:00:00Z")
        fake.add("Report.pdf", data: Data("new!".utf8), id: "BBBBBBBBnew", created: "2026-01-01T00:00:00Z")
        let service = try Self.service(fake)
        let names = try await service.listDirectory(at: "/").map(\.name)
        #expect(names.sorted() == ["report.pdf", "Report (BBBBBBBB).pdf"].sorted())
        #expect(try await service.itemInfo(at: "/Report (BBBBBBBB).pdf").size == 4)
        #expect(try await service.itemInfo(at: "/report.pdf").size == 3)
    }

    @Test("Google 文件以 Office 格式唯讀匯出，無法匯出的類型略過")
    func exportsGoogleDocuments() async throws {
        let fake = FakeDrive()
        fake.add("預算", mimeType: "application/vnd.google-apps.spreadsheet")
        fake.add("問卷", mimeType: "application/vnd.google-apps.form")
        let service = try Self.service(fake)
        let items = try await service.listDirectory(at: "/")
        #expect(items.map(\.name) == ["預算.xlsx"])
        #expect(items[0].permissions == 0o444)

        let destination = CloudFixtures.temporaryURL()
        try await service.downloadFile(at: "/預算.xlsx", to: destination, progress: nil)
        let exported = String(decoding: try Data(contentsOf: destination), as: UTF8.self)
        #expect(exported.hasPrefix("EXPORT:預算:application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"))

        await #expect(throws: RemoteFileServiceError.permissionDenied(operation: "upload", path: "/預算.xlsx")) {
            try await service.uploadFile(from: try CloudFixtures.temporaryFile(Data()), to: "/預算.xlsx", progress: nil)
        }
    }

    @Test("名稱中的斜線顯示為冒號，寫回時還原")
    func mapsSlashesInNames() async throws {
        let fake = FakeDrive()
        fake.add("a/b.txt", data: Data("x".utf8))
        let service = try Self.service(fake)
        #expect(try await service.listDirectory(at: "/").map(\.name) == ["a:b.txt"])
        try await service.moveItem(from: "/a:b.txt", to: "/c:d.txt")
        #expect(fake.named("c/d.txt").count == 1)
    }

    /// A colon is a character of its own on Drive, not a slash: shown as
    /// one it would be written back as a slash, and a name with each would
    /// collide.
    @Test("名稱中的冒號另外顯示，改名後原樣寫回")
    func keepsColonsApartFromSlashes() async throws {
        let fake = FakeDrive()
        fake.add("c:d.txt", data: Data("colon".utf8))
        fake.add("c/d.txt", data: Data("slash".utf8))
        let service = try Self.service(fake)
        #expect(try await service.listDirectory(at: "/").map(\.name).sorted() == ["c:d.txt", "c\u{A789}d.txt"])
        #expect(try await service.itemInfo(at: "/c\u{A789}d.txt").size == 5)

        try await service.moveItem(from: "/c\u{A789}d.txt", to: "/e\u{A789}f.txt")
        #expect(fake.named("e:f.txt").count == 1)
        #expect(fake.named("c/d.txt").count == 1)
    }

    @Test("捷徑視為目標項目")
    func followsShortcuts() async throws {
        let fake = FakeDrive()
        let shared = fake.add("共用", in: "elsewhere", mimeType: GoogleDriveFileService.folderType)
        fake.add("inside.txt", in: shared, data: Data("in".utf8))
        fake.addShortcut("共用捷徑", to: shared)
        let service = try Self.service(fake)
        let item = try await service.itemInfo(at: "/共用捷徑")
        #expect(item.isDirectory)
        #expect(item.isResolvedLink)
        #expect(try await service.listDirectory(at: "/共用捷徑").map(\.name) == ["inside.txt"])
    }

    @Test("上傳新檔與覆寫既有檔都走續傳上傳")
    func uploadsNewAndExistingFiles() async throws {
        let fake = FakeDrive()
        let folder = fake.add("docs", mimeType: GoogleDriveFileService.folderType)
        let service = try Self.service(fake)
        let first = CloudFixtures.bytes(2_000)
        try await service.uploadFile(from: try CloudFixtures.temporaryFile(first), to: "/docs/n.bin", progress: nil)
        let created = fake.named("n.bin")
        #expect(created.count == 1)
        #expect(created[0].parents == [folder])
        #expect(created[0].data == first)

        let second = CloudFixtures.bytes(3_000)
        try await service.uploadFile(from: try CloudFixtures.temporaryFile(second), to: "/docs/n.bin", progress: nil)
        #expect(fake.named("n.bin").count == 1)
        #expect(fake.file(created[0].id)?.data == second)

        let range = try await service.downloadRange(at: "/docs/n.bin", offset: 10, length: 20)
        #expect(range == second.subdata(in: 10..<30))
    }

    @Test("建立資料夾不重複，刪除移到垃圾桶，搬移換父資料夾")
    func createsTrashesAndMoves() async throws {
        let fake = FakeDrive()
        let a = fake.add("a", mimeType: GoogleDriveFileService.folderType)
        let b = fake.add("b", mimeType: GoogleDriveFileService.folderType)
        let file = fake.add("f.txt", in: a, data: Data("f".utf8))
        let service = try Self.service(fake)
        try await service.createDirectory(at: "/c")
        await #expect(throws: RemoteFileServiceError.alreadyExists(path: "/c")) {
            try await service.createDirectory(at: "/c")
        }
        try await service.moveItem(from: "/a/f.txt", to: "/b/f.txt")
        #expect(fake.file(file)?.parents == [b])
        try await service.deleteFile(at: "/b/f.txt")
        #expect(fake.file(file)?.trashed == true)
        await #expect(throws: RemoteFileServiceError.itemNotFound(path: "/b/f.txt")) {
            _ = try await service.itemInfo(at: "/b/f.txt")
        }
    }

    @Test("以 403 回報的速率限制會等待後重試")
    func retriesRateLimits() async throws {
        let fake = FakeDrive()
        fake.add("x.txt")
        fake.rateLimitedListings = 1
        let service = try Self.service(fake)
        #expect(try await service.listDirectory(at: "/").map(\.name) == ["x.txt"])
    }

    @Test("掛載子資料夾，權杖過期時更新")
    func mountsAFolder() async throws {
        let fake = FakeDrive()
        let work = fake.add("Work", mimeType: GoogleDriveFileService.folderType)
        fake.add("todo.md", in: work)
        let service = try Self.service(
            fake, remotePath: "/Work", token: CloudFixtures.token(provider: .google, access: "x", expiresIn: -10))
        #expect(try await service.listDirectory(at: "/").map(\.path) == ["/todo.md"])
        #expect(fake.tokens.refreshCount == 1)
    }
}
