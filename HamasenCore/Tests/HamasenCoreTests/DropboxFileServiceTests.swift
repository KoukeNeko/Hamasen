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

/// An in-memory Dropbox speaking enough of the v2 API for the client:
/// case-insensitive paths, 409 error summaries, paged listings, ranged
/// downloads, upload sessions, and access tokens that expire.
final class FakeDropbox: @unchecked Sendable {
    struct Entry {
        var display: String
        var isFolder: Bool
        var data = Data()
        var revision = 1
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var sessions: [String: Data] = [:]
    let tokens = StubTokenIssuer()
    /// Small, so a listing has to follow its cursor.
    let pageSize = 2
    private(set) var headerArguments: [String] = []

    init(files: [String: Data] = [:], folders: [String] = []) {
        for folder in folders { entries[folder.lowercased()] = Entry(display: folder, isFolder: true) }
        for (path, data) in files { entries[path.lowercased()] = Entry(display: path, isFolder: false, data: data) }
    }

    func contents(of path: String) -> Data? { lock.withLock { entries[path.lowercased()]?.data } }
    func exists(_ path: String) -> Bool { lock.withLock { entries[path.lowercased()] != nil } }
    var arguments: [String] { lock.withLock { headerArguments } }

    func session() -> URLSession {
        StubURLProtocol.session { [self] request in handle(request) }
    }

    private func handle(_ request: StubRequest) -> StubResponse {
        if tokens.isTokenRequest(request) { return tokens.handle(request) }
        guard tokens.accepts(request) else {
            return .json(["error_summary": "expired_access_token/", "error": [".tag": "expired_access_token"]], status: 401)
        }
        return lock.withLock { route(request) }
    }

    private func route(_ request: StubRequest) -> StubResponse {
        let route = request.url.path.replacingOccurrences(of: "/2/", with: "")
        if request.url.host == "content.dropboxapi.com" {
            let argument = request.header("Dropbox-API-Arg") ?? "{}"
            headerArguments.append(argument)
            let json = (try? JSONSerialization.jsonObject(with: Data(argument.utf8))) as? [String: Any] ?? [:]
            return content(route, arguments: json, request: request)
        }
        return rpc(route, arguments: request.json)
    }

    private func metadata(_ entry: Entry) -> [String: Any] {
        var object: [String: Any] = [
            ".tag": entry.isFolder ? "folder" : "file",
            "name": (entry.display as NSString).lastPathComponent,
            "path_display": entry.display,
            "path_lower": entry.display.lowercased(),
        ]
        if !entry.isFolder {
            object["size"] = entry.data.count
            object["rev"] = "rev\(entry.revision)"
            object["content_hash"] = "hash-\(entry.data.count)-\(entry.revision)"
            object["server_modified"] = "2026-09-30T12:00:00Z"
            object["client_modified"] = "2026-09-29T12:00:00Z"
        }
        return object
    }

    private func conflict(_ summary: String) -> StubResponse {
        .json(["error_summary": summary], status: 409)
    }

    private func children(of folder: String) -> [Entry] {
        let prefix = folder.isEmpty ? "/" : folder.lowercased() + "/"
        return entries.filter { key, _ in
            key.hasPrefix(prefix) && !key.dropFirst(prefix.count).contains("/")
        }.map(\.value).sorted { $0.display < $1.display }
    }

    private func rpc(_ route: String, arguments: [String: Any]) -> StubResponse {
        switch route {
        case "users/get_current_account":
            return .json(["email": "someone@example.com", "name": ["display_name": "Someone"]])
        case "files/list_folder", "files/list_folder/continue":
            let path: String
            let start: Int
            if let cursor = arguments["cursor"] as? String {
                let parts = cursor.split(separator: "|", maxSplits: 1)
                start = Int(parts[0]) ?? 0
                path = parts.count > 1 ? String(parts[1]) : ""
            } else {
                path = arguments["path"] as? String ?? ""
                start = 0
                if !path.isEmpty, entries[path.lowercased()]?.isFolder != true { return conflict("path/not_found/..") }
            }
            let all = children(of: path)
            let page = Array(all.dropFirst(start).prefix(pageSize))
            let next = start + page.count
            return .json([
                "entries": page.map(metadata), "cursor": "\(next)|\(path)", "has_more": next < all.count,
            ])
        case "files/get_metadata":
            guard let entry = entries[(arguments["path"] as? String ?? "").lowercased()] else {
                return conflict("path/not_found/..")
            }
            return .json(metadata(entry))
        case "files/create_folder_v2":
            let path = arguments["path"] as? String ?? ""
            if entries[path.lowercased()] != nil { return conflict("path/conflict/folder/..") }
            entries[path.lowercased()] = Entry(display: path, isFolder: true)
            return .json(["metadata": metadata(entries[path.lowercased()]!)])
        case "files/delete_v2":
            let path = (arguments["path"] as? String ?? "").lowercased()
            guard entries[path] != nil else { return conflict("path_lookup/not_found/..") }
            entries = entries.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
            return .json(["metadata": [:]])
        case "files/move_v2":
            let from = (arguments["from_path"] as? String ?? "")
            let to = (arguments["to_path"] as? String ?? "")
            guard entries[from.lowercased()] != nil else { return conflict("from_lookup/not_found/..") }
            if entries[to.lowercased()] != nil { return conflict("to/conflict/file/..") }
            var moved: [String: Entry] = [:]
            for (key, var entry) in entries {
                if key == from.lowercased() || key.hasPrefix(from.lowercased() + "/") {
                    entry.display = to + entry.display.dropFirst(from.count)
                    moved[entry.display.lowercased()] = entry
                } else {
                    moved[key] = entry
                }
            }
            entries = moved
            return .json(["metadata": metadata(entries[to.lowercased()]!)])
        case "files/search_v2":
            let query = (arguments["query"] as? String ?? "").lowercased()
            let matches = entries.values.filter { ($0.display as NSString).lastPathComponent.lowercased().contains(query) }
            return .json(["matches": matches.map { ["metadata": [".tag": "metadata", "metadata": metadata($0)]] }])
        default:
            return .status(404)
        }
    }

    private func content(_ route: String, arguments: [String: Any], request: StubRequest) -> StubResponse {
        switch route {
        case "files/download":
            guard let entry = entries[(arguments["path"] as? String ?? "").lowercased()], !entry.isFolder else {
                return conflict("path/not_found/..")
            }
            if let range = request.header("Range"), let bounds = Self.bounds(range, size: entry.data.count) {
                return StubResponse(status: 206, body: entry.data.subdata(in: bounds))
            }
            return StubResponse(status: 200, body: entry.data)
        case "files/upload":
            return commit(arguments, data: request.body)
        case "files/upload_session/start":
            let id = UUID().uuidString
            sessions[id] = request.body
            return .json(["session_id": id])
        case "files/upload_session/append_v2", "files/upload_session/finish":
            let cursor = arguments["cursor"] as? [String: Any] ?? [:]
            guard let id = cursor["session_id"] as? String, var data = sessions[id] else { return .status(400) }
            guard (cursor["offset"] as? Int) == data.count else { return conflict("incorrect_offset/..") }
            data.append(request.body)
            sessions[id] = data
            if route.hasSuffix("finish") {
                return commit(arguments["commit"] as? [String: Any] ?? [:], data: data)
            }
            return .json([:])
        default:
            return .status(404)
        }
    }

    private func commit(_ arguments: [String: Any], data: Data) -> StubResponse {
        let path = arguments["path"] as? String ?? ""
        var entry = entries[path.lowercased()] ?? Entry(display: path, isFolder: false)
        entry.data = data
        entry.revision += 1
        entries[path.lowercased()] = entry
        return .json(metadata(entry))
    }

    static func bounds(_ header: String, size: Int) -> Range<Int>? {
        let numbers = header.replacingOccurrences(of: "bytes=", with: "").split(separator: "-").compactMap { Int($0) }
        guard numbers.count == 2, numbers[0] < size else { return nil }
        return numbers[0]..<min(numbers[1] + 1, size)
    }
}

@Suite("DropboxFileService")
struct DropboxFileServiceTests {
    private static func service(
        _ fake: FakeDropbox, remotePath: String = "/", token: OAuthToken = CloudFixtures.token(provider: .dropbox)
    ) throws -> DropboxFileService {
        try DropboxFileService(
            config: CloudFixtures.config(.dropbox, remotePath: remotePath),
            credentials: .oauth(token),
            urlSession: fake.session(),
            keychain: CloudFixtures.keychain)
    }

    @Test("列出資料夾會跟著 cursor 讀完每一頁")
    func listsEveryPage() async throws {
        let fake = FakeDropbox(files: ["/a.txt": Data("a".utf8), "/b.txt": Data("bb".utf8), "/c.txt": Data()], folders: ["/照片"])
        let service = try Self.service(fake)
        try await service.connect()
        let items = try await service.listDirectory(at: "/")
        #expect(items.map(\.name).sorted() == ["a.txt", "b.txt", "c.txt", "照片"])
        #expect(items.first { $0.name == "照片" }?.isDirectory == true)
        #expect(items.first { $0.name == "b.txt" }?.size == 2)
    }

    @Test("掛載子資料夾時路徑相對於該資料夾")
    func mountsAFolder() async throws {
        let fake = FakeDropbox(files: ["/Work/plan.md": Data("x".utf8)], folders: ["/Work"])
        let service = try Self.service(fake, remotePath: "/Work")
        try await service.connect()
        let items = try await service.listDirectory(at: "/")
        #expect(items.map(\.path) == ["/plan.md"])
        let info = try await service.itemInfo(at: "/plan.md")
        #expect(info.size == 1)
    }

    @Test("上傳、下載與部分下載的內容一致，中文檔名以跳脫字元送出")
    func roundTripsContent() async throws {
        let fake = FakeDropbox()
        let service = try Self.service(fake)
        let payload = CloudFixtures.bytes(10_000)
        let source = try CloudFixtures.temporaryFile(payload)
        try await service.uploadFile(from: source, to: "/報告.pdf", progress: nil)
        #expect(fake.contents(of: "/報告.pdf") == payload)
        let argumentsAreASCII = fake.arguments.allSatisfy { $0.unicodeScalars.allSatisfy { $0.isASCII } }
        #expect(argumentsAreASCII)

        let destination = CloudFixtures.temporaryURL()
        try await service.downloadFile(at: "/報告.pdf", to: destination, progress: nil)
        #expect(try Data(contentsOf: destination) == payload)

        let range = try await service.downloadRange(at: "/報告.pdf", offset: 100, length: 50)
        #expect(range == payload.subdata(in: 100..<150))
    }

    @Test("大檔案分段上傳，最後一段才提交")
    func uploadsLargeFilesInSessions() async throws {
        let fake = FakeDropbox()
        let service = try Self.service(fake)
        let payload = CloudFixtures.bytes(Int(DropboxFileService.singleUploadLimit) + 1_000)
        let source = try CloudFixtures.temporaryFile(payload)
        try await service.uploadFile(from: source, to: "/big.bin", progress: nil)
        #expect(fake.contents(of: "/big.bin") == payload)
    }

    @Test("存取權杖過期時會更新後重試")
    func renewsAnExpiredToken() async throws {
        let fake = FakeDropbox(files: ["/a.txt": Data("a".utf8)])
        let service = try Self.service(fake, token: CloudFixtures.token(provider: .dropbox, access: "stale"))
        let items = try await service.listDirectory(at: "/")
        #expect(items.count == 1)
        #expect(fake.tokens.refreshCount == 1)
    }

    @Test("建立、搬移與刪除對應到 409 錯誤")
    func mapsConflictsAndMissingItems() async throws {
        let fake = FakeDropbox(files: ["/a.txt": Data("a".utf8), "/b.txt": Data("b".utf8)])
        let service = try Self.service(fake)
        try await service.createDirectory(at: "/新資料夾")
        await #expect(throws: RemoteFileServiceError.alreadyExists(path: "/新資料夾")) {
            try await service.createDirectory(at: "/新資料夾")
        }
        await #expect(throws: RemoteFileServiceError.alreadyExists(path: "/b.txt")) {
            try await service.moveItem(from: "/a.txt", to: "/b.txt")
        }
        try await service.moveItem(from: "/a.txt", to: "/新資料夾/a.txt")
        #expect(fake.exists("/新資料夾/a.txt"))
        try await service.deleteDirectory(at: "/新資料夾")
        #expect(!fake.exists("/新資料夾/a.txt"))
        await #expect(throws: RemoteFileServiceError.itemNotFound(path: "/missing.txt")) {
            _ = try await service.itemInfo(at: "/missing.txt")
        }
    }

    @Test("搜尋使用 Dropbox 的搜尋 API")
    func searches() async throws {
        let fake = FakeDropbox(files: ["/docs/budget-2026.xlsx": Data(), "/notes.txt": Data()], folders: ["/docs"])
        let service = try Self.service(fake)
        let found = try await service.searchItems(matching: "budget", under: "/", limit: 10)
        #expect(found.map(\.path) == ["/docs/budget-2026.xlsx"])
    }

    @Test("Dropbox-API-Arg 中的非 ASCII 字元會跳脫")
    func escapesHeaderArguments() {
        let header = DropboxFileService.headerArgument(["path": "/照片/a.jpg"])
        let isASCII = header.unicodeScalars.allSatisfy { $0.isASCII }
        #expect(isASCII)
        let decoded = try? JSONSerialization.jsonObject(with: Data(header.utf8)) as? [String: String]
        #expect(decoded == ["path": "/照片/a.jpg"])
    }
}
