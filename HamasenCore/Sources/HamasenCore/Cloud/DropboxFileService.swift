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

/// Dropbox through its v2 HTTP API.
///
/// Dropbox addresses everything by path, which is what `RemoteFileService`
/// speaks, so the mapping is direct: the mount's root is the folder the
/// connection names, "" to Dropbox when that is the whole account.
public actor DropboxFileService: RemoteFileService {
    static let apiBase = URL(string: "https://api.dropboxapi.com/2/")!
    static let contentBase = URL(string: "https://content.dropboxapi.com/2/")!

    /// Dropbox takes up to 150 MB in one upload request; above that it
    /// wants an upload session. Sessions are used from well below the
    /// ceiling, so one failed request costs a chunk rather than the file.
    static let singleUploadLimit: Int64 = 32 * 1024 * 1024
    static let uploadChunkSize = 16 * 1024 * 1024

    private static let log = HamasenLog(category: "dropbox")

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
        _ = try await rpc("users/get_current_account", arguments: nil)
        // A missing root folder is a configuration mistake worth reporting
        // now rather than as an empty mount.
        if config.remotePath != RemotePath.root {
            _ = try await metadata(atAbsolute: config.remotePath)
        }
        hasConnected = true
    }

    public func disconnect() async throws {
        hasConnected = false
    }

    public var isConnected: Bool { hasConnected }

    public func checkReachable() async throws {
        _ = try await rpc("users/get_current_account", arguments: nil)
    }

    /// The signed-in account's address, for naming the connection.
    public func accountEmail() async throws -> String {
        let account = try await rpc("users/get_current_account", arguments: nil)
        return account["email"] as? String ?? ""
    }

    // MARK: - Listing

    public func listDirectory(at path: String) async throws -> [RemoteItem] {
        var result = try await rpc(
            "files/list_folder",
            arguments: ["path": Self.apiPath(absolutePath(path)), "limit": 2000, "include_deleted": false],
            path: path)
        var items = parseEntries(result["entries"])
        while result["has_more"] as? Bool == true, let cursor = result["cursor"] as? String {
            try Task.checkCancellation()
            result = try await rpc("files/list_folder/continue", arguments: ["cursor": cursor], path: path)
            items += parseEntries(result["entries"])
        }
        return items
    }

    public func itemInfo(at path: String) async throws -> RemoteItem {
        if path == RemotePath.root {
            // Dropbox has no metadata for the account root, and a folder
            // named as the mount's root is described as a folder anyway.
            if config.remotePath != RemotePath.root {
                _ = try await metadata(atAbsolute: config.remotePath)
            }
            return RemoteItem(path: RemotePath.root, name: RemotePath.root, kind: .directory, size: 0)
        }
        let entry = try await metadata(atAbsolute: absolutePath(path))
        guard let item = parseEntry(entry) else { throw RemoteFileServiceError.itemNotFound(path: path) }
        return item
    }

    // MARK: - Transfers

    public func downloadFile(at path: String, to localURL: URL, progress: TransferProgress?) async throws {
        var request = URLRequest.cloud(Self.contentBase.appending(path: "files/download"), method: "POST")
        request.setValue(Self.headerArgument(["path": absolutePath(path)]), forHTTPHeaderField: "Dropbox-API-Arg")
        let (data, response) = try await http.download(request, to: localURL, progress: progress)
        try check(response, data: data, path: path, operation: "download")
    }

    public func downloadRange(at path: String, offset: Int64, length: Int) async throws -> Data {
        guard length > 0 else { return Data() }
        var request = URLRequest.cloud(Self.contentBase.appending(path: "files/download"), method: "POST")
        request.setValue(Self.headerArgument(["path": absolutePath(path)]), forHTTPHeaderField: "Dropbox-API-Arg")
        request.setValue("bytes=\(offset)-\(offset + Int64(length) - 1)", forHTTPHeaderField: "Range")
        let (data, response) = try await http.send(request)
        if response.statusCode == 416 { return Data() }
        try check(response, data: data, path: path, operation: "download")
        // A response that ignored the range carries the whole file.
        if response.statusCode == 200, data.count > length {
            let start = Int(min(offset, Int64(data.count)))
            return data.subdata(in: start..<min(start + length, data.count))
        }
        return data
    }

    public func uploadFile(from localURL: URL, to path: String, progress: TransferProgress?) async throws {
        let size = Int64((try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard FileManager.default.isReadableFile(atPath: localURL.path) else {
            throw RemoteFileServiceError.localFileUnreadable(url: localURL)
        }
        let commit: [String: Any] = [
            "path": absolutePath(path), "mode": "overwrite", "autorename": false, "mute": true,
        ]
        if size <= Self.singleUploadLimit {
            var request = URLRequest.cloud(Self.contentBase.appending(path: "files/upload"), method: "POST")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue(Self.headerArgument(commit), forHTTPHeaderField: "Dropbox-API-Arg")
            let (data, response) = try await http.send(request, body: .file(localURL), progress: progress)
            try check(response, data: data, path: path, operation: "upload")
            return
        }
        try await uploadInSession(from: localURL, size: size, commit: commit, path: path, progress: progress)
    }

    /// Sends a large file a chunk at a time and commits it under its name
    /// only once every byte is there, so an interrupted upload never
    /// replaces the file with part of the new one.
    private func uploadInSession(
        from localURL: URL, size: Int64, commit: [String: Any], path: String, progress: TransferProgress?
    ) async throws {
        let file = try FileHandle(forReadingFrom: localURL)
        defer { try? file.close() }

        var offset: Int64 = 0
        var sessionID: String?
        while offset < size {
            try Task.checkCancellation()
            let chunk = try file.read(upToCount: Self.uploadChunkSize) ?? Data()
            guard !chunk.isEmpty else { break }
            let isLast = offset + Int64(chunk.count) >= size
            let sent = offset
            let reporter: TransferProgress? = progress.map { report in { @Sendable bytes in report(sent + bytes) } }

            var request: URLRequest
            if let sessionID {
                if isLast {
                    request = URLRequest.cloud(Self.contentBase.appending(path: "files/upload_session/finish"), method: "POST")
                    request.setValue(Self.headerArgument([
                        "cursor": ["session_id": sessionID, "offset": offset], "commit": commit,
                    ]), forHTTPHeaderField: "Dropbox-API-Arg")
                } else {
                    request = URLRequest.cloud(Self.contentBase.appending(path: "files/upload_session/append_v2"), method: "POST")
                    request.setValue(Self.headerArgument([
                        "cursor": ["session_id": sessionID, "offset": offset], "close": false,
                    ]), forHTTPHeaderField: "Dropbox-API-Arg")
                }
            } else {
                request = URLRequest.cloud(Self.contentBase.appending(path: "files/upload_session/start"), method: "POST")
                request.setValue(Self.headerArgument(["close": false]), forHTTPHeaderField: "Dropbox-API-Arg")
            }
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await http.send(request, body: .data(chunk), progress: reporter)
            try check(response, data: data, path: path, operation: "upload")
            if sessionID == nil {
                guard let started = CloudJSON.object(data)?["session_id"] as? String else {
                    throw RemoteFileServiceError.operationFailed(
                        operation: "upload", path: path, underlying: "no upload session")
                }
                sessionID = started
                // A file that fit in one chunk still has to be committed.
                if isLast {
                    offset += Int64(chunk.count)
                    try await finishEmptySession(sessionID: started, offset: offset, commit: commit, path: path)
                    return
                }
            }
            offset += Int64(chunk.count)
        }
    }

    private func finishEmptySession(
        sessionID: String, offset: Int64, commit: [String: Any], path: String
    ) async throws {
        var request = URLRequest.cloud(Self.contentBase.appending(path: "files/upload_session/finish"), method: "POST")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.headerArgument([
            "cursor": ["session_id": sessionID, "offset": offset], "commit": commit,
        ]), forHTTPHeaderField: "Dropbox-API-Arg")
        let (data, response) = try await http.send(request, body: .data(Data()))
        try check(response, data: data, path: path, operation: "upload")
    }

    // MARK: - Changes

    public func createDirectory(at path: String) async throws {
        _ = try await rpc(
            "files/create_folder_v2", arguments: ["path": absolutePath(path), "autorename": false],
            path: path, operation: "mkdir")
    }

    public func deleteFile(at path: String) async throws {
        try await delete(path)
    }

    /// Dropbox deletes a folder with everything in it, and keeps what it
    /// deletes recoverable for its retention period.
    public func deleteDirectory(at path: String) async throws {
        try await delete(path)
    }

    private func delete(_ path: String) async throws {
        _ = try await rpc("files/delete_v2", arguments: ["path": absolutePath(path)], path: path, operation: "delete")
    }

    public func moveItem(from oldPath: String, to newPath: String) async throws {
        _ = try await rpc(
            "files/move_v2",
            arguments: [
                "from_path": absolutePath(oldPath), "to_path": absolutePath(newPath),
                "autorename": false, "allow_ownership_transfer": false,
            ],
            path: oldPath, operation: "move", destination: newPath)
    }

    public func searchItems(matching query: String, under path: String, limit: Int) async throws -> [RemoteItem] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, limit > 0 else { return [] }
        let result = try await rpc(
            "files/search_v2",
            arguments: [
                "query": query,
                "options": [
                    "path": Self.apiPath(absolutePath(path)), "max_results": min(limit, 1000),
                    "filename_only": true,
                ] as [String: Any],
            ],
            path: path)
        let matches = result["matches"] as? [[String: Any]] ?? []
        let entries = matches.compactMap { match -> [String: Any]? in
            (match["metadata"] as? [String: Any])?["metadata"] as? [String: Any]
        }
        return Array(entries.compactMap(parseEntry).prefix(limit))
    }

    // MARK: - Requests

    private func absolutePath(_ path: String) -> String {
        CloudPath.absolute(path, base: config.remotePath)
    }

    /// Dropbox names its root "" rather than "/".
    static func apiPath(_ absolute: String) -> String {
        absolute == RemotePath.root ? "" : absolute
    }

    private func metadata(atAbsolute absolute: String) async throws -> [String: Any] {
        let path = CloudPath.mountRelative(absolute, base: config.remotePath) ?? absolute
        return try await rpc("files/get_metadata", arguments: ["path": absolute], path: path)
    }

    /// Calls an RPC endpoint. A nil argument sends the JSON `null` that
    /// parameterless endpoints expect.
    private func rpc(
        _ route: String, arguments: [String: Any]?, path: String = RemotePath.root,
        operation: String = "list", destination: String? = nil
    ) async throws -> [String: Any] {
        let request = URLRequest.cloud(Self.apiBase.appending(path: route), method: "POST", json: true)
        let body = arguments.map(CloudJSON.encode) ?? Data("null".utf8)
        let (data, response) = try await http.send(request, body: .data(body))
        try check(response, data: data, path: path, operation: operation, destination: destination)
        return CloudJSON.object(data) ?? [:]
    }

    /// Maps a failed response onto the shared error type. Dropbox reports
    /// endpoint-specific failures as 409 with a summary such as
    /// `path/not_found/..` or `to/conflict/folder/..`.
    private func check(
        _ response: HTTPURLResponse, data: Data, path: String, operation: String, destination: String? = nil
    ) throws {
        guard !(200...299).contains(response.statusCode) else { return }
        let summary = CloudJSON.object(data)?["error_summary"] as? String
            ?? String(decoding: data.prefix(300), as: UTF8.self)
        Self.log.debug("\(operation) \(path) failed: HTTP \(response.statusCode) \(summary)")
        switch response.statusCode {
        case 401:
            throw RemoteFileServiceError.authenticationFailed
        case 403:
            throw RemoteFileServiceError.permissionDenied(operation: operation, path: path)
        case 409:
            if summary.contains("not_found") {
                throw RemoteFileServiceError.itemNotFound(path: path)
            }
            if summary.contains("conflict") {
                throw RemoteFileServiceError.alreadyExists(path: destination ?? path)
            }
            if summary.contains("no_write_permission") || summary.contains("disallowed") {
                throw RemoteFileServiceError.permissionDenied(operation: operation, path: path)
            }
            throw RemoteFileServiceError.operationFailed(operation: operation, path: path, underlying: summary)
        default:
            throw RemoteFileServiceError.operationFailed(
                operation: operation, path: path, underlying: "HTTP \(response.statusCode) \(summary)")
        }
    }

    // MARK: - Parsing

    private func parseEntries(_ value: Any?) -> [RemoteItem] {
        (value as? [[String: Any]] ?? []).compactMap(parseEntry)
    }

    private func parseEntry(_ entry: [String: Any]) -> RemoteItem? {
        guard let tag = entry[".tag"] as? String, tag == "file" || tag == "folder",
              let name = entry["name"] as? String,
              let display = entry["path_display"] as? String,
              let path = CloudPath.mountRelative(display, base: config.remotePath),
              path != RemotePath.root
        else { return nil }
        if tag == "folder" {
            return RemoteItem(path: path, name: name, kind: .directory, size: 0)
        }
        return RemoteItem(
            path: path,
            name: name,
            kind: .file,
            size: CloudJSON.int64(entry["size"]) ?? 0,
            modificationDate: CloudJSON.date(entry["server_modified"]),
            creationDate: CloudJSON.date(entry["client_modified"]),
            contentTag: entry["content_hash"] as? String ?? entry["rev"] as? String
        )
    }

    /// The `Dropbox-API-Arg` header carries JSON, and an HTTP header is
    /// ASCII: anything else is written as a `\u` escape, or a file named in
    /// Chinese arrives mangled.
    static func headerArgument(_ object: [String: Any]) -> String {
        let json = String(decoding: CloudJSON.encode(object), as: UTF8.self)
        var escaped = ""
        for unit in json.utf16 {
            if unit < 0x80 {
                escaped.unicodeScalars.append(Unicode.Scalar(unit)!)
            } else {
                escaped += String(format: "\\u%04x", unit)
            }
        }
        return escaped
    }
}
