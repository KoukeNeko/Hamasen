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

/// An in-memory OneDrive speaking enough of Microsoft Graph for the client:
/// path addressing (`/root:/a/b:`), paged children, upload sessions on a
/// pre-signed host that refuses the account's token, and moves by
/// destination ID.
final class FakeGraph: @unchecked Sendable {
    struct Item {
        let id: String
        var path: String
        var isFolder: Bool
        var data = Data()
        var version = 1
    }

    private let lock = NSLock()
    private var items: [String: Item] = [:]
    private var sessions: [String: (path: String, data: Data)] = [:]
    let tokens = StubTokenIssuer()
    let pageSize = 2
    private(set) var tokenSentToUploadHost = false

    init(files: [String: Data] = [:], folders: [String] = []) {
        items["/"] = Item(id: "root-id", path: "/", isFolder: true)
        for folder in folders { items[folder.lowercased()] = Item(id: UUID().uuidString, path: folder, isFolder: true) }
        for (path, data) in files {
            items[path.lowercased()] = Item(id: UUID().uuidString, path: path, isFolder: false, data: data)
        }
    }

    func contents(of path: String) -> Data? { lock.withLock { items[path.lowercased()]?.data } }
    func exists(_ path: String) -> Bool { lock.withLock { items[path.lowercased()] != nil } }
    var uploadHostSawToken: Bool { lock.withLock { tokenSentToUploadHost } }

    func session() -> URLSession {
        StubURLProtocol.session { [self] request in handle(request) }
    }

    private func handle(_ request: StubRequest) -> StubResponse {
        if tokens.isTokenRequest(request) { return tokens.handle(request) }
        if request.url.host == "upload.example.com" {
            return lock.withLock { uploadChunk(request) }
        }
        guard tokens.accepts(request) else {
            return .json(["error": ["code": "InvalidAuthenticationToken", "message": "expired"]], status: 401)
        }
        return lock.withLock { route(request) }
    }

    private func notFound() -> StubResponse {
        .json(["error": ["code": "itemNotFound", "message": "not found"]], status: 404)
    }

    private func json(_ item: Item) -> [String: Any] {
        let parent = (item.path as NSString).deletingLastPathComponent
        var object: [String: Any] = [
            "id": item.id,
            "name": item.path == "/" ? "root" : (item.path as NSString).lastPathComponent,
            "lastModifiedDateTime": "2026-09-30T12:00:00.123Z",
            "createdDateTime": "2026-09-29T12:00:00Z",
            "parentReference": ["path": "/drive/root:" + (parent == "/" ? "" : parent)],
        ]
        if item.isFolder {
            object["folder"] = ["childCount": 0]
        } else {
            object["file"] = ["mimeType": "application/octet-stream"]
            object["size"] = item.data.count
            object["cTag"] = "ctag-\(item.version)"
        }
        return object
    }

    /// Splits `/v1.0/me/drive/root:/a/b:/children` into the item path and
    /// what follows it.
    private func address(_ url: URL) -> (path: String, action: String)? {
        let full = url.path(percentEncoded: false)
        guard let range = full.range(of: "/v1.0/me/drive/root") else { return nil }
        var rest = String(full[range.upperBound...])
        if rest.hasPrefix(":") {
            rest.removeFirst()
            guard let end = rest.range(of: ":") else { return nil }
            let path = String(rest[..<end.lowerBound])
            return (path, String(rest[end.upperBound...]))
        }
        return ("/", rest)
    }

    private func route(_ request: StubRequest) -> StubResponse {
        if request.url.path.hasSuffix("/v1.0/me") {
            return .json(["mail": "someone@example.com", "userPrincipalName": "someone@example.com"])
        }
        if request.url.path(percentEncoded: false).contains("search(q=") {
            let query = request.url.path(percentEncoded: false).components(separatedBy: "'")[1].lowercased()
            let found = items.values.filter { $0.path != "/" && ($0.path as NSString).lastPathComponent.lowercased().contains(query) }
            return .json(["value": found.map(json)])
        }
        guard let (path, action) = address(request.url) else { return .status(400) }
        let key = path.lowercased()
        switch (request.method, action) {
        case ("GET", ""):
            guard let item = items[key] else { return notFound() }
            return .json(json(item))
        case ("GET", "/children"):
            guard items[key]?.isFolder == true else { return notFound() }
            let prefix = key == "/" ? "/" : key + "/"
            let children = items.values.filter {
                $0.path != "/" && $0.path.lowercased().hasPrefix(prefix)
                    && !$0.path.lowercased().dropFirst(prefix.count).contains("/")
            }.sorted { $0.path < $1.path }
            let skip = Int(request.query("$skiptoken") ?? "0") ?? 0
            let page = Array(children.dropFirst(skip).prefix(pageSize))
            var body: [String: Any] = ["value": page.map(json)]
            if skip + page.count < children.count {
                var components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!
                components.queryItems = (components.queryItems ?? []).filter { $0.name != "$skiptoken" }
                    + [URLQueryItem(name: "$skiptoken", value: String(skip + page.count))]
                body["@odata.nextLink"] = components.url!.absoluteString
            }
            return .json(body)
        case ("GET", "/content"):
            guard let item = items[key], !item.isFolder else { return notFound() }
            if let range = request.header("Range"), let bounds = FakeDropbox.bounds(range, size: item.data.count) {
                return StubResponse(status: 206, body: item.data.subdata(in: bounds))
            }
            return StubResponse(status: 200, body: item.data)
        case ("PUT", "/content"):
            return store(request.body, at: path)
        case ("POST", "/createUploadSession"):
            let id = UUID().uuidString
            sessions[id] = (path, Data())
            return .json(["uploadUrl": "https://upload.example.com/session/\(id)"])
        case ("POST", "/children"):
            let body = request.json
            let name = body["name"] as? String ?? ""
            let child = path == "/" ? "/" + name : path + "/" + name
            if items[child.lowercased()] != nil {
                return .json(["error": ["code": "nameAlreadyExists", "message": "exists"]], status: 409)
            }
            items[child.lowercased()] = Item(id: UUID().uuidString, path: child, isFolder: true)
            return .json(json(items[child.lowercased()]!), status: 201)
        case ("DELETE", ""):
            guard items[key] != nil else { return notFound() }
            items = items.filter { $0.key != key && !$0.key.hasPrefix(key + "/") }
            return .status(204)
        case ("PATCH", ""):
            guard let item = items[key] else { return notFound() }
            let body = request.json
            var parent = (item.path as NSString).deletingLastPathComponent
            if let id = (body["parentReference"] as? [String: Any])?["id"] as? String {
                guard let destination = items.values.first(where: { $0.id == id }) else { return notFound() }
                parent = destination.path
            }
            let name = body["name"] as? String ?? (item.path as NSString).lastPathComponent
            let target = parent == "/" ? "/" + name : parent + "/" + name
            if items[target.lowercased()] != nil, request.query("@microsoft.graph.conflictBehavior") == "fail" {
                return .json(["error": ["code": "nameAlreadyExists", "message": "exists"]], status: 409)
            }
            var moved: [String: Item] = [:]
            for (existingKey, var entry) in items {
                if existingKey == key || existingKey.hasPrefix(key + "/") {
                    entry.path = target + entry.path.dropFirst(item.path.count)
                    moved[entry.path.lowercased()] = entry
                } else {
                    moved[existingKey] = entry
                }
            }
            items = moved
            return .json(json(items[target.lowercased()]!))
        default:
            return .status(400)
        }
    }

    private func store(_ data: Data, at path: String) -> StubResponse {
        var item = items[path.lowercased()] ?? Item(id: UUID().uuidString, path: path, isFolder: false)
        item.data = data
        item.version += 1
        items[path.lowercased()] = item
        return .json(json(item), status: 201)
    }

    private func uploadChunk(_ request: StubRequest) -> StubResponse {
        if request.header("Authorization") != nil { tokenSentToUploadHost = true }
        let id = request.url.lastPathComponent
        guard var session = sessions[id], let range = request.header("Content-Range") else { return .status(400) }
        let numbers = range.replacingOccurrences(of: "bytes ", with: "")
            .split(whereSeparator: { $0 == "-" || $0 == "/" }).compactMap { Int($0) }
        guard numbers.count == 3, numbers[0] == session.data.count else { return .status(416) }
        session.data.append(request.body)
        sessions[id] = session
        if session.data.count == numbers[2] {
            return store(session.data, at: session.path)
        }
        return .json(["nextExpectedRanges": ["\(session.data.count)-"]], status: 202)
    }
}

@Suite("OneDriveFileService")
struct OneDriveFileServiceTests {
    private static func service(
        _ fake: FakeGraph, remotePath: String = "/", token: OAuthToken = CloudFixtures.token(provider: .microsoft)
    ) throws -> OneDriveFileService {
        try OneDriveFileService(
            config: CloudFixtures.config(.oneDrive, remotePath: remotePath),
            credentials: .oauth(token),
            urlSession: fake.session(),
            keychain: CloudFixtures.keychain)
    }

    @Test("以路徑定址並讀完每一頁子項目")
    func listsByPath() async throws {
        let fake = FakeGraph(
            files: ["/文件/a #1.txt": Data("a".utf8), "/文件/b?.txt": Data("bb".utf8), "/文件/c.txt": Data()],
            folders: ["/文件"])
        let service = try Self.service(fake)
        try await service.connect()
        let items = try await service.listDirectory(at: "/文件")
        #expect(items.map(\.name) == ["a #1.txt", "b?.txt", "c.txt"])
        let info = try await service.itemInfo(at: "/文件/b?.txt")
        #expect(info.size == 2)
        #expect(info.contentTag == "ctag-1")
    }

    @Test("小檔案直接上傳，大檔案分段且不把權杖送往上傳網址")
    func uploadsSmallAndLargeFiles() async throws {
        let fake = FakeGraph()
        let service = try Self.service(fake)
        let small = CloudFixtures.bytes(1_000)
        try await service.uploadFile(from: try CloudFixtures.temporaryFile(small), to: "/small.bin", progress: nil)
        #expect(fake.contents(of: "/small.bin") == small)

        let large = CloudFixtures.bytes(Int(OneDriveFileService.singleUploadLimit) + OneDriveFileService.uploadChunkSize + 77)
        try await service.uploadFile(from: try CloudFixtures.temporaryFile(large), to: "/large.bin", progress: nil)
        #expect(fake.contents(of: "/large.bin") == large)
        #expect(!fake.uploadHostSawToken)
    }

    @Test("下載整檔與部分範圍")
    func downloads() async throws {
        let payload = CloudFixtures.bytes(5_000)
        let fake = FakeGraph(files: ["/v.mov": payload])
        let service = try Self.service(fake)
        let destination = CloudFixtures.temporaryURL()
        try await service.downloadFile(at: "/v.mov", to: destination, progress: nil)
        #expect(try Data(contentsOf: destination) == payload)
        #expect(try await service.downloadRange(at: "/v.mov", offset: 4_990, length: 100) == payload.subdata(in: 4_990..<5_000))
    }

    @Test("改名、搬移與衝突")
    func renamesAndMoves() async throws {
        let fake = FakeGraph(files: ["/a.txt": Data("a".utf8), "/b.txt": Data()], folders: ["/dir"])
        let service = try Self.service(fake)
        await #expect(throws: RemoteFileServiceError.alreadyExists(path: "/b.txt")) {
            try await service.moveItem(from: "/a.txt", to: "/b.txt")
        }
        try await service.moveItem(from: "/a.txt", to: "/dir/renamed.txt")
        #expect(fake.contents(of: "/dir/renamed.txt") == Data("a".utf8))
        try await service.createDirectory(at: "/dir/sub")
        await #expect(throws: RemoteFileServiceError.alreadyExists(path: "/dir/sub")) {
            try await service.createDirectory(at: "/dir/sub")
        }
        try await service.deleteDirectory(at: "/dir")
        #expect(!fake.exists("/dir/renamed.txt"))
    }

    @Test("搜尋結果只留在搜尋的資料夾之下")
    func searchesWithinScope() async throws {
        let fake = FakeGraph(files: ["/work/plan.txt": Data(), "/home/plan.txt": Data()], folders: ["/work", "/home"])
        let service = try Self.service(fake)
        let found = try await service.searchItems(matching: "plan", under: "/work", limit: 10)
        #expect(found.map(\.path) == ["/work/plan.txt"])
    }

    @Test("掛載子資料夾，權杖被拒時更新")
    func mountsAFolderAndRenewsTokens() async throws {
        let fake = FakeGraph(files: ["/Projects/x.txt": Data("x".utf8)], folders: ["/Projects"])
        let service = try Self.service(
            fake, remotePath: "/Projects", token: CloudFixtures.token(provider: .microsoft, access: "stale"))
        let items = try await service.listDirectory(at: "/")
        #expect(items.map(\.path) == ["/x.txt"])
        #expect(fake.tokens.refreshCount == 1)
    }
}
