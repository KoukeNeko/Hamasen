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

/// OneDrive through Microsoft Graph.
///
/// Graph can address an item by path (`/root:/a/b:`), so most calls map
/// straight across; only a move needs the destination folder's ID, which is
/// looked up for it.
public actor OneDriveFileService: RemoteFileService {
    static let driveBase = "https://graph.microsoft.com/v1.0/me/drive"

    /// Graph takes a body up to 4 MB in one PUT; larger files go through an
    /// upload session, in chunks that must be multiples of 320 KiB.
    static let singleUploadLimit: Int64 = 4 * 1024 * 1024
    static let uploadChunkSize = 32 * 327_680

    private static let itemFields =
        "id,name,size,file,folder,package,lastModifiedDateTime,createdDateTime,cTag,eTag,parentReference"

    private static let log = HamasenLog(category: "onedrive")

    private let config: ServerConfig
    private let http: CloudHTTPClient
    private var hasConnected = false

    public init(
        config: ServerConfig,
        credentials: ServerCredentials,
        connectTimeoutSeconds: Int = AppSettings.defaultConnectTimeoutSeconds,
        urlSession: URLSession? = nil,
        keychain: any OAuthTokenStore = KeychainCredentialStore()
    ) throws {
        guard case .oauth(let token) = credentials else {
            throw RemoteFileServiceError.unsupportedCredentials(protocolName: config.transferProtocol.displayName)
        }
        let session = urlSession ?? CloudHTTPClient.makeSession(connectTimeoutSeconds: connectTimeoutSeconds)
        self.config = config
        self.http = CloudHTTPClient(
            auth: OAuthSession(token: token, serverID: config.id, store: keychain, urlSession: session),
            urlSession: session,
            ownsSession: urlSession == nil)
    }

    // MARK: - Connection

    public func connect() async throws {
        guard !hasConnected else { return }
        _ = try await itemInfo(at: RemotePath.root)
        hasConnected = true
    }

    public func disconnect() async throws {
        hasConnected = false
    }

    public var isConnected: Bool { hasConnected }

    /// The signed-in account, for naming the connection.
    public func accountEmail() async throws -> String {
        let url = URL(string: "https://graph.microsoft.com/v1.0/me?$select=userPrincipalName,mail")!
        let (data, response) = try await http.send(.cloud(url))
        try check(response, data: data, path: RemotePath.root, operation: "account")
        let me = CloudJSON.object(data) ?? [:]
        return me["mail"] as? String ?? me["userPrincipalName"] as? String ?? ""
    }

    // MARK: - Listing

    public func listDirectory(at path: String) async throws -> [RemoteItem] {
        var next: URL? = url(for: path, suffix: "/children?$top=999&$select=\(Self.itemFields)")
        var items: [RemoteItem] = []
        while let page = next {
            try Task.checkCancellation()
            let (data, response) = try await http.send(.cloud(page))
            try check(response, data: data, path: path, operation: "list")
            let body = CloudJSON.object(data) ?? [:]
            let entries = body["value"] as? [[String: Any]] ?? []
            items += entries.compactMap { parse($0, inDirectory: path) }
            next = (body["@odata.nextLink"] as? String).flatMap(URL.init(string:))
        }
        return items
    }

    public func itemInfo(at path: String) async throws -> RemoteItem {
        let (data, response) = try await http.send(.cloud(url(for: path, suffix: "?$select=\(Self.itemFields)")))
        try check(response, data: data, path: path, operation: "stat")
        if path == RemotePath.root {
            return RemoteItem(path: RemotePath.root, name: RemotePath.root, kind: .directory, size: 0)
        }
        guard let object = CloudJSON.object(data), let item = parse(object, inDirectory: RemotePath.parent(of: path))
        else { throw RemoteFileServiceError.itemNotFound(path: path) }
        return item
    }

    // MARK: - Transfers

    /// `/content` answers with a redirect to a pre-signed address, which
    /// URLSession follows without carrying the Authorization header across.
    public func downloadFile(at path: String, to localURL: URL, progress: TransferProgress?) async throws {
        let (data, response) = try await http.download(
            .cloud(url(for: path, suffix: "/content")), to: localURL, progress: progress)
        try check(response, data: data, path: path, operation: "download")
    }

    public func downloadRange(at path: String, offset: Int64, length: Int) async throws -> Data {
        guard length > 0 else { return Data() }
        var request = URLRequest.cloud(url(for: path, suffix: "/content"))
        request.setValue("bytes=\(offset)-\(offset + Int64(length) - 1)", forHTTPHeaderField: "Range")
        let (data, response) = try await http.send(request)
        if response.statusCode == 416 { return Data() }
        try check(response, data: data, path: path, operation: "download")
        if response.statusCode == 200, data.count > length {
            let start = Int(min(offset, Int64(data.count)))
            return data.subdata(in: start..<min(start + length, data.count))
        }
        return data
    }

    public func uploadFile(from localURL: URL, to path: String, progress: TransferProgress?) async throws {
        guard FileManager.default.isReadableFile(atPath: localURL.path) else {
            throw RemoteFileServiceError.localFileUnreadable(url: localURL)
        }
        let size = Int64((try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        if size <= Self.singleUploadLimit {
            var request = URLRequest.cloud(url(for: path, suffix: "/content"), method: "PUT")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await http.send(request, body: .file(localURL), progress: progress)
            try check(response, data: data, path: path, operation: "upload")
            return
        }
        try await uploadInSession(from: localURL, size: size, to: path, progress: progress)
    }

    /// An upload session replaces the file only when its last chunk lands,
    /// so an interrupted upload leaves the old version in place.
    private func uploadInSession(
        from localURL: URL, size: Int64, to path: String, progress: TransferProgress?
    ) async throws {
        let create = URLRequest.cloud(url(for: path, suffix: "/createUploadSession"), method: "POST", json: true)
        let (created, createResponse) = try await http.send(
            create, body: .data(CloudJSON.encode(["item": ["@microsoft.graph.conflictBehavior": "replace"]])))
        try check(createResponse, data: created, path: path, operation: "upload")
        guard let uploadURL = (CloudJSON.object(created)?["uploadUrl"] as? String).flatMap(URL.init(string:)) else {
            throw RemoteFileServiceError.operationFailed(operation: "upload", path: path, underlying: "no upload URL")
        }

        let file = try FileHandle(forReadingFrom: localURL)
        defer { try? file.close() }
        var offset: Int64 = 0
        while offset < size {
            try Task.checkCancellation()
            let chunk = try file.read(upToCount: Self.uploadChunkSize) ?? Data()
            guard !chunk.isEmpty else { break }
            let end = offset + Int64(chunk.count) - 1
            var request = URLRequest.cloud(uploadURL, method: "PUT")
            request.setValue("bytes \(offset)-\(end)/\(size)", forHTTPHeaderField: "Content-Range")
            let sent = offset
            let reporter: TransferProgress? = progress.map { report in { @Sendable bytes in report(sent + bytes) } }
            // The session URL is pre-signed, and Graph refuses a chunk that
            // also carries the account's token.
            let (data, response) = try await http.send(
                request, body: .data(chunk), authorized: false, progress: reporter)
            try check(response, data: data, path: path, operation: "upload")
            offset = end + 1
        }
    }

    // MARK: - Changes

    public func createDirectory(at path: String) async throws {
        let parent = RemotePath.parent(of: path)
        let request = URLRequest.cloud(url(for: parent, suffix: "/children"), method: "POST", json: true)
        let body = CloudJSON.encode([
            "name": RemotePath.name(of: path), "folder": [String: Any](),
            "@microsoft.graph.conflictBehavior": "fail",
        ])
        let (data, response) = try await http.send(request, body: .data(body))
        try check(response, data: data, path: path, operation: "mkdir")
    }

    public func deleteFile(at path: String) async throws {
        try await delete(path)
    }

    /// Graph deletes a folder with its contents, into the recycle bin.
    public func deleteDirectory(at path: String) async throws {
        try await delete(path)
    }

    private func delete(_ path: String) async throws {
        let (data, response) = try await http.send(.cloud(url(for: path, suffix: ""), method: "DELETE"))
        try check(response, data: data, path: path, operation: "delete")
    }

    public func moveItem(from oldPath: String, to newPath: String) async throws {
        var changes: [String: Any] = ["name": RemotePath.name(of: newPath)]
        if RemotePath.parent(of: oldPath) != RemotePath.parent(of: newPath) {
            changes["parentReference"] = ["id": try await itemID(at: RemotePath.parent(of: newPath))]
        }
        // Asked to fail on a name already taken, as SFTP's rename does, so
        // Finder can offer its own prompt instead of an item being replaced.
        let request = URLRequest.cloud(
            url(for: oldPath, suffix: "?@microsoft.graph.conflictBehavior=fail"), method: "PATCH", json: true)
        let (data, response) = try await http.send(request, body: .data(CloudJSON.encode(changes)))
        try check(response, data: data, path: oldPath, operation: "move", destination: newPath)
    }

    /// Graph hands out each item's page as `webUrl`.
    public func browserURL(for path: String) async throws -> URL? {
        let (data, response) = try await http.send(.cloud(url(for: path, suffix: "?$select=webUrl")))
        try check(response, data: data, path: path, operation: "stat")
        return (CloudJSON.object(data)?["webUrl"] as? String).flatMap(URL.init(string:))
    }

    private func itemID(at path: String) async throws -> String {
        let (data, response) = try await http.send(.cloud(url(for: path, suffix: "?$select=id")))
        try check(response, data: data, path: path, operation: "stat")
        guard let id = CloudJSON.object(data)?["id"] as? String else {
            throw RemoteFileServiceError.itemNotFound(path: path)
        }
        return id
    }

    /// Graph's search covers the whole drive, so what it returns is kept
    /// only where it lies under the folder being searched.
    public func searchItems(matching query: String, under path: String, limit: Int) async throws -> [RemoteItem] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, limit > 0 else { return [] }
        let escaped = query.replacingOccurrences(of: "'", with: "''")
        let encoded = escaped.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? escaped
        let searchURL = URL(string: "\(Self.driveBase)/root/search(q='\(encoded)')?$top=\(min(limit * 2, 200))&$select=\(Self.itemFields)")!
        let (data, response) = try await http.send(.cloud(searchURL))
        try check(response, data: data, path: path, operation: "search")
        let entries = CloudJSON.object(data)?["value"] as? [[String: Any]] ?? []
        let scope = RemotePath.withoutTrailingSeparator(path)
        let found = entries.compactMap { entry -> RemoteItem? in
            guard let directory = Self.mountRelativeParent(of: entry, base: config.remotePath) else { return nil }
            guard scope == RemotePath.root || directory == scope || directory.hasPrefix(scope + "/") else {
                return nil
            }
            return parse(entry, inDirectory: directory)
        }
        return Array(found.prefix(limit))
    }

    // MARK: - Addressing

    static let unreserved: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    /// The item URL for a mount-relative path: `/root` for the drive's top,
    /// `/root:/a/b:` for anything below it. Every segment is encoded, since
    /// a "#" or "?" in a file name would otherwise end the path.
    func url(for path: String, suffix: String) -> URL {
        let absolute = CloudPath.absolute(path, base: config.remotePath)
        let address: String
        if absolute == RemotePath.root {
            address = "\(Self.driveBase)/root\(suffix)"
        } else {
            let encoded = absolute.split(separator: "/").map {
                String($0).addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? String($0)
            }.joined(separator: "/")
            address = "\(Self.driveBase)/root:/\(encoded):\(suffix)"
        }
        return URL(string: address)!
    }

    /// `parentReference.path` reads `/drive/root:/a/b`; the part after the
    /// colon is the folder on the drive.
    static func mountRelativeParent(of entry: [String: Any], base: String) -> String? {
        guard let reference = (entry["parentReference"] as? [String: Any])?["path"] as? String,
              let colon = reference.firstIndex(of: ":")
        else { return nil }
        var absolute = String(reference[reference.index(after: colon)...])
        absolute = absolute.removingPercentEncoding ?? absolute
        if absolute.isEmpty { absolute = RemotePath.root }
        return CloudPath.mountRelative(absolute, base: base)
    }

    // MARK: - Responses

    private func check(
        _ response: HTTPURLResponse, data: Data, path: String, operation: String, destination: String? = nil
    ) throws {
        guard !(200...299).contains(response.statusCode) else { return }
        let error = CloudJSON.object(data)?["error"] as? [String: Any]
        let code = error?["code"] as? String ?? ""
        let message = error?["message"] as? String ?? String(decoding: data.prefix(300), as: UTF8.self)
        Self.log.debug("\(operation) \(path) failed: HTTP \(response.statusCode) \(code) \(message)")
        switch response.statusCode {
        case 401:
            throw RemoteFileServiceError.authenticationFailed
        case 403:
            throw RemoteFileServiceError.permissionDenied(operation: operation, path: path)
        case 404:
            throw RemoteFileServiceError.itemNotFound(path: path)
        case 409:
            throw RemoteFileServiceError.alreadyExists(path: destination ?? path)
        default:
            throw RemoteFileServiceError.operationFailed(
                operation: operation, path: path, underlying: "HTTP \(response.statusCode) \(message)")
        }
    }

    /// OneNote notebooks are packages Graph cannot hand over as files or
    /// list as folders, so they are left out.
    private func parse(_ entry: [String: Any], inDirectory directory: String) -> RemoteItem? {
        guard let name = entry["name"] as? String, entry["package"] == nil else { return nil }
        let path = RemotePath.join(directory, name)
        if entry["folder"] != nil {
            return RemoteItem(
                path: path, name: name, kind: .directory, size: 0,
                modificationDate: CloudJSON.date(entry["lastModifiedDateTime"]),
                creationDate: CloudJSON.date(entry["createdDateTime"]))
        }
        return RemoteItem(
            path: path,
            name: name,
            kind: .file,
            size: CloudJSON.int64(entry["size"]) ?? 0,
            modificationDate: CloudJSON.date(entry["lastModifiedDateTime"]),
            creationDate: CloudJSON.date(entry["createdDateTime"]),
            // The cTag changes with the content and only with it; the eTag
            // also moves on a rename.
            contentTag: entry["cTag"] as? String
        )
    }
}
