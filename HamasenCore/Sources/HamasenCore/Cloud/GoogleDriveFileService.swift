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

/// Google Drive through its v3 API.
///
/// Drive is a graph of IDs, not a tree of paths: a folder can hold two files
/// with the same name, a name can contain "/", and Google's own documents
/// have no bytes of their own. Everything here exists to present that as
/// the path tree `RemoteFileService` speaks, the same way on every call:
///
/// - Paths are resolved one folder at a time from the mount's root, with
///   each folder's listing kept for a few seconds so a deep path is not a
///   request per component on every call.
/// - Names sharing a folder get the item's ID appended, except the oldest,
///   so every item has a path and the same item always has the same one.
/// - A "/" in a name is shown as ":", which is how macOS stores a "/" typed
///   in Finder, and turned back on the way to Drive.
/// - Docs, Sheets, Slides and Drawings are exported as Office files and PDF,
///   read-only; Google types with no export are left out.
/// - Shortcuts behave as what they point at.
public actor GoogleDriveFileService: RemoteFileService {
    static let apiBase = "https://www.googleapis.com/drive/v3"
    static let uploadBase = "https://www.googleapis.com/upload/drive/v3"
    static let folderType = "application/vnd.google-apps.folder"
    static let shortcutType = "application/vnd.google-apps.shortcut"
    private static let googleTypePrefix = "application/vnd.google-apps."

    private static let fileFields =
        "id,name,mimeType,size,modifiedTime,createdTime,md5Checksum,version,shortcutDetails,capabilities(canEdit)"

    /// How long a folder's listing answers path lookups before it is fetched
    /// again. Short, because another device may change the folder at any
    /// time; long enough that one Finder operation resolving the same parent
    /// a dozen times asks once.
    private static let listingLifetime: TimeInterval = 10

    struct ExportFormat: Equatable, Sendable {
        let mimeType: String
        let fileExtension: String
    }

    static let exportFormats: [String: ExportFormat] = [
        "application/vnd.google-apps.document": ExportFormat(
            mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            fileExtension: "docx"),
        "application/vnd.google-apps.spreadsheet": ExportFormat(
            mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            fileExtension: "xlsx"),
        "application/vnd.google-apps.presentation": ExportFormat(
            mimeType: "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            fileExtension: "pptx"),
        "application/vnd.google-apps.drawing": ExportFormat(mimeType: "application/pdf", fileExtension: "pdf"),
    ]

    /// One Drive item as it appears at a path.
    struct Node: Sendable, Equatable {
        /// The item itself, which renames, moves and deletes act on.
        let id: String
        /// What content and children are read from: the target, for a
        /// shortcut.
        let contentID: String
        let displayName: String
        let isFolder: Bool
        let isShortcut: Bool
        let export: ExportFormat?
        let size: Int64
        let modified: Date?
        let created: Date?
        let tag: String?
        let canEdit: Bool

        func remoteItem(at path: String) -> RemoteItem {
            RemoteItem(
                path: path,
                name: displayName,
                kind: isFolder ? .directory : .file,
                size: isFolder ? 0 : size,
                modificationDate: modified,
                creationDate: created,
                permissions: isFolder ? nil : (export != nil || isShortcut || !canEdit ? 0o444 : nil),
                contentTag: isFolder ? nil : tag,
                isResolvedLink: isShortcut)
        }

        /// Whether the bytes can be replaced: never for an export or a
        /// shortcut, whose bytes are not the item's own.
        var acceptsContent: Bool { !isFolder && export == nil && !isShortcut && canEdit }
    }

    private struct Listing {
        let fetchedAt: Date
        let nodes: [Node]
    }

    private static let log = HamasenLog(category: "googledrive")

    private let config: ServerConfig
    private let http: CloudHTTPClient
    private var hasConnected = false
    private var rootNode: Node?
    private var listings: [String: Listing] = [:]

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
            ownsSession: urlSession == nil,
            isThrottled: { status, data in Self.isRateLimited(status, data) })
    }

    // MARK: - Connection

    public func connect() async throws {
        guard !hasConnected else { return }
        _ = try await root()
        hasConnected = true
    }

    public func disconnect() async throws {
        hasConnected = false
        listings.removeAll()
        rootNode = nil
    }

    public var isConnected: Bool { hasConnected }

    public func checkReachable() async throws {
        _ = try await get(URL(string: "\(Self.apiBase)/about?fields=user(emailAddress)")!, path: RemotePath.root)
    }

    /// The signed-in account, for naming the connection.
    public func accountEmail() async throws -> String {
        let about = try await get(
            URL(string: "\(Self.apiBase)/about?fields=user(emailAddress)")!, path: RemotePath.root)
        return (about["user"] as? [String: Any])?["emailAddress"] as? String ?? ""
    }

    // MARK: - Listing

    public func listDirectory(at path: String) async throws -> [RemoteItem] {
        let folder = try await node(at: path)
        guard folder.isFolder else {
            throw RemoteFileServiceError.operationFailed(operation: "list", path: path, underlying: "not a folder")
        }
        let nodes = try await children(of: folder, path: path, fresh: true)
        return nodes.map { $0.remoteItem(at: RemotePath.join(path, $0.displayName)) }
    }

    public func itemInfo(at path: String) async throws -> RemoteItem {
        try await node(at: path).remoteItem(at: path)
    }

    // MARK: - Transfers

    public func downloadFile(at path: String, to localURL: URL, progress: TransferProgress?) async throws {
        let file = try await node(at: path)
        let (data, response) = try await http.download(
            URLRequest.cloud(contentURL(for: file)), to: localURL, progress: progress)
        try check(response, data: data, path: path, operation: "download")
    }

    /// An export cannot be read by range, so its whole conversion is fetched
    /// and the range cut from it; exports are documents, not videos.
    public func downloadRange(at path: String, offset: Int64, length: Int) async throws -> Data {
        guard length > 0 else { return Data() }
        let file = try await node(at: path)
        var request = URLRequest.cloud(contentURL(for: file))
        if file.export == nil {
            request.setValue("bytes=\(offset)-\(offset + Int64(length) - 1)", forHTTPHeaderField: "Range")
        }
        let (data, response) = try await http.send(request)
        if response.statusCode == 416 { return Data() }
        try check(response, data: data, path: path, operation: "download")
        if response.statusCode == 200, file.export != nil || data.count > length {
            let start = Int(min(offset, Int64(data.count)))
            return data.subdata(in: start..<min(start + length, data.count))
        }
        return data
    }

    public func uploadFile(from localURL: URL, to path: String, progress: TransferProgress?) async throws {
        guard FileManager.default.isReadableFile(atPath: localURL.path) else {
            throw RemoteFileServiceError.localFileUnreadable(url: localURL)
        }
        let parentPath = RemotePath.parent(of: path)
        let parent = try await folder(at: parentPath)
        let size = Int64((try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let existing = try await children(of: parent, path: parentPath, fresh: true)
            .first { Self.sameName($0.displayName, RemotePath.name(of: path)) }

        let initiation: URLRequest
        let metadata: [String: Any]
        if let existing {
            guard existing.acceptsContent else {
                if existing.isFolder { throw RemoteFileServiceError.alreadyExists(path: path) }
                throw RemoteFileServiceError.permissionDenied(operation: "upload", path: path)
            }
            initiation = .cloud(
                URL(string: "\(Self.uploadBase)/files/\(existing.id)?uploadType=resumable&supportsAllDrives=true&fields=id")!,
                method: "PATCH", json: true)
            metadata = [:]
        } else {
            initiation = .cloud(
                URL(string: "\(Self.uploadBase)/files?uploadType=resumable&supportsAllDrives=true&fields=id")!,
                method: "POST", json: true)
            metadata = ["name": Self.driveName(RemotePath.name(of: path)), "parents": [parent.contentID]]
        }
        var start = initiation
        start.setValue(String(size), forHTTPHeaderField: "X-Upload-Content-Length")
        let (startData, startResponse) = try await http.send(start, body: .data(CloudJSON.encode(metadata)))
        try check(startResponse, data: startData, path: path, operation: "upload")
        guard let location = startResponse.value(forHTTPHeaderField: "Location").flatMap(URL.init(string:)) else {
            throw RemoteFileServiceError.operationFailed(operation: "upload", path: path, underlying: "no upload session")
        }

        // The session address is what authorizes the bytes; the whole file
        // goes in one request, which Drive accepts at any size.
        var put = URLRequest.cloud(location, method: "PUT")
        put.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await http.send(put, body: .file(localURL), progress: progress)
        forget(parent)
        try check(response, data: data, path: path, operation: "upload")
    }

    // MARK: - Changes

    public func createDirectory(at path: String) async throws {
        let parentPath = RemotePath.parent(of: path)
        let parent = try await folder(at: parentPath)
        // Drive would happily make a second folder of the same name.
        if try await children(of: parent, path: parentPath, fresh: true)
            .contains(where: { Self.sameName($0.displayName, RemotePath.name(of: path)) }) {
            throw RemoteFileServiceError.alreadyExists(path: path)
        }
        let request = URLRequest.cloud(
            URL(string: "\(Self.apiBase)/files?supportsAllDrives=true&fields=id")!, method: "POST", json: true)
        let body = CloudJSON.encode([
            "name": Self.driveName(RemotePath.name(of: path)), "mimeType": Self.folderType,
            "parents": [parent.contentID],
        ])
        let (data, response) = try await http.send(request, body: .data(body))
        forget(parent)
        try check(response, data: data, path: path, operation: "mkdir")
    }

    public func deleteFile(at path: String) async throws {
        try await trash(path)
    }

    public func deleteDirectory(at path: String) async throws {
        try await trash(path)
    }

    /// Into Drive's trash rather than gone, the way deleting in Drive's own
    /// apps works; trashing a folder takes what is inside with it.
    private func trash(_ path: String) async throws {
        let item = try await node(at: path)
        let request = URLRequest.cloud(
            URL(string: "\(Self.apiBase)/files/\(item.id)?supportsAllDrives=true&fields=id")!,
            method: "PATCH", json: true)
        let (data, response) = try await http.send(request, body: .data(CloudJSON.encode(["trashed": true])))
        listings.removeAll()
        try check(response, data: data, path: path, operation: "delete")
    }

    public func moveItem(from oldPath: String, to newPath: String) async throws {
        let item = try await node(at: oldPath)
        let oldParentPath = RemotePath.parent(of: oldPath)
        let newParentPath = RemotePath.parent(of: newPath)
        let oldParent = try await folder(at: oldParentPath)
        let newParent = try await folder(at: newParentPath)
        let newName = RemotePath.name(of: newPath)
        if try await children(of: newParent, path: newParentPath, fresh: true)
            .contains(where: { Self.sameName($0.displayName, newName) && $0.id != item.id }) {
            throw RemoteFileServiceError.alreadyExists(path: newPath)
        }

        var query = "supportsAllDrives=true&fields=id"
        if oldParent.contentID != newParent.contentID {
            query += "&addParents=\(newParent.contentID)&removeParents=\(oldParent.contentID)"
        }
        var changes: [String: Any] = [:]
        if newName != item.displayName {
            changes["name"] = Self.driveName(Self.strippingExport(newName, export: item.export))
        }
        let request = URLRequest.cloud(
            URL(string: "\(Self.apiBase)/files/\(item.id)?\(query)")!, method: "PATCH", json: true)
        let (data, response) = try await http.send(request, body: .data(CloudJSON.encode(changes)))
        listings.removeAll()
        try check(response, data: data, path: oldPath, operation: "move", destination: newPath)
    }

    // MARK: - Resolving paths

    private func root() async throws -> Node {
        if let rootNode { return rootNode }
        let myDrive = try await get(
            URL(string: "\(Self.apiBase)/files/root?fields=\(Self.fileFields)&supportsAllDrives=true")!,
            path: RemotePath.root)
        guard var current = Self.node(from: myDrive) else {
            throw RemoteFileServiceError.itemNotFound(path: RemotePath.root)
        }
        // The configured root folder is resolved the same way as any path,
        // name by name from My Drive.
        for component in config.remotePath.split(separator: "/").map(String.init) {
            let nodes = try await fetchChildren(of: current)
            guard let next = nodes.first(where: { Self.sameName($0.displayName, component) }), next.isFolder else {
                throw RemoteFileServiceError.itemNotFound(path: config.remotePath)
            }
            current = next
        }
        rootNode = current
        return current
    }

    private func node(at path: String) async throws -> Node {
        var current = try await root()
        var walked = RemotePath.root
        for component in path.split(separator: "/").map(String.init) {
            guard current.isFolder else { throw RemoteFileServiceError.itemNotFound(path: path) }
            let nodes = try await children(of: current, path: walked, fresh: false)
            guard let next = nodes.first(where: { Self.sameName($0.displayName, component) }) else {
                throw RemoteFileServiceError.itemNotFound(path: path)
            }
            walked = RemotePath.join(walked, component)
            current = next
        }
        return current
    }

    private func folder(at path: String) async throws -> Node {
        let found = try await node(at: path)
        guard found.isFolder else { throw RemoteFileServiceError.itemNotFound(path: path) }
        return found
    }

    private func children(of folder: Node, path: String, fresh: Bool) async throws -> [Node] {
        if !fresh, let cached = listings[folder.contentID],
           Date().timeIntervalSince(cached.fetchedAt) < Self.listingLifetime {
            return cached.nodes
        }
        do {
            return try await fetchChildren(of: folder)
        } catch RemoteFileServiceError.itemNotFound {
            throw RemoteFileServiceError.itemNotFound(path: path)
        }
    }

    private func fetchChildren(of folder: Node) async throws -> [Node] {
        let query = "'\(Self.escapedQueryValue(folder.contentID))' in parents and trashed = false"
        var pageToken: String?
        var raw: [[String: Any]] = []
        repeat {
            try Task.checkCancellation()
            var components = URLComponents(string: "\(Self.apiBase)/files")!
            components.queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "fields", value: "nextPageToken,files(\(Self.fileFields))"),
                URLQueryItem(name: "pageSize", value: "1000"),
                URLQueryItem(name: "supportsAllDrives", value: "true"),
                URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
            ] + (pageToken.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
            let page = try await get(components.url!, path: folder.displayName)
            raw += page["files"] as? [[String: Any]] ?? []
            pageToken = page["nextPageToken"] as? String
        } while pageToken != nil
        let nodes = Self.disambiguated(raw)
        listings[folder.contentID] = Listing(fetchedAt: Date(), nodes: nodes)
        return nodes
    }

    private func forget(_ folder: Node) {
        listings[folder.contentID] = nil
    }

    // MARK: - Mapping Drive items

    /// Builds the nodes of one folder, naming each so that no two collide.
    ///
    /// Collisions are judged ignoring case, as the Mac's file system does.
    /// The oldest item keeps its name; the rest get their ID appended, which
    /// stays the same however the folder is listed.
    static func disambiguated(_ files: [[String: Any]]) -> [Node] {
        let candidates = files.compactMap { file -> (Node, Date)? in
            guard let node = node(from: file) else { return nil }
            return (node, node.created ?? .distantPast)
        }
        let groups = Dictionary(grouping: candidates) { $0.0.displayName.lowercased() }
        var nodes: [Node] = []
        for (_, group) in groups {
            let ordered = group.sorted { lhs, rhs in
                lhs.1 != rhs.1 ? lhs.1 < rhs.1 : lhs.0.id < rhs.0.id
            }
            for (index, entry) in ordered.enumerated() {
                let node = entry.0
                guard index > 0 else {
                    nodes.append(node)
                    continue
                }
                nodes.append(Node(
                    id: node.id, contentID: node.contentID,
                    displayName: suffixed(node.displayName, with: String(node.id.prefix(8)), isFolder: node.isFolder),
                    isFolder: node.isFolder, isShortcut: node.isShortcut, export: node.export,
                    size: node.size, modified: node.modified, created: node.created, tag: node.tag,
                    canEdit: node.canEdit))
            }
        }
        return nodes.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    static func node(from file: [String: Any]) -> Node? {
        guard let id = file["id"] as? String, let name = file["name"] as? String,
              var mimeType = file["mimeType"] as? String
        else { return nil }
        var contentID = id
        var isShortcut = false
        if mimeType == shortcutType {
            guard let details = file["shortcutDetails"] as? [String: Any],
                  let targetID = details["targetId"] as? String,
                  let targetType = details["targetMimeType"] as? String
            else { return nil }
            contentID = targetID
            mimeType = targetType
            isShortcut = true
        }
        let isFolder = mimeType == folderType
        let export = exportFormats[mimeType]
        // Forms, Sites, Maps and the rest have nothing that can be fetched.
        if !isFolder, export == nil, mimeType.hasPrefix(googleTypePrefix) { return nil }

        var displayName = name.replacingOccurrences(of: "/", with: ":")
        if let export, !displayName.lowercased().hasSuffix("." + export.fileExtension) {
            displayName += "." + export.fileExtension
        }
        let version = CloudJSON.int64(file["version"]).map { "v\($0)" }
        let canEdit = (file["capabilities"] as? [String: Any])?["canEdit"] as? Bool ?? true
        return Node(
            id: id, contentID: contentID, displayName: displayName, isFolder: isFolder,
            isShortcut: isShortcut, export: export,
            size: CloudJSON.int64(file["size"]) ?? 0,
            modified: CloudJSON.date(file["modifiedTime"]),
            created: CloudJSON.date(file["createdTime"]),
            // A shortcut's own version says nothing about its target's bytes.
            tag: isShortcut ? nil : (file["md5Checksum"] as? String ?? version),
            canEdit: canEdit)
    }

    /// "report.pdf" with suffix "1AbC" becomes "report (1AbC).pdf".
    static func suffixed(_ name: String, with suffix: String, isFolder: Bool) -> String {
        let fileExtension = (name as NSString).pathExtension
        guard !isFolder, !fileExtension.isEmpty else { return "\(name) (\(suffix))" }
        return "\((name as NSString).deletingPathExtension) (\(suffix)).\(fileExtension)"
    }

    /// The name to store on Drive: ":" back to the "/" it stood for.
    static func driveName(_ displayName: String) -> String {
        displayName.replacingOccurrences(of: ":", with: "/")
    }

    /// An exported document renamed in Finder keeps the extension Hamasen
    /// added; Drive's own name never had it.
    static func strippingExport(_ name: String, export: ExportFormat?) -> String {
        guard let export, name.lowercased().hasSuffix("." + export.fileExtension) else { return name }
        return String(name.dropLast(export.fileExtension.count + 1))
    }

    static func sameName(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive]) == .orderedSame
    }

    /// Drive's query language quotes values in single quotes and escapes
    /// with a backslash.
    static func escapedQueryValue(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }

    private func contentURL(for file: Node) -> URL {
        if let export = file.export {
            var components = URLComponents(string: "\(Self.apiBase)/files/\(file.contentID)/export")!
            components.queryItems = [URLQueryItem(name: "mimeType", value: export.mimeType)]
            return components.url!
        }
        return URL(string: "\(Self.apiBase)/files/\(file.contentID)?alt=media&supportsAllDrives=true")!
    }

    // MARK: - Responses

    private func get(_ url: URL, path: String) async throws -> [String: Any] {
        let (data, response) = try await http.send(.cloud(url))
        try check(response, data: data, path: path, operation: "list")
        return CloudJSON.object(data) ?? [:]
    }

    /// Some of Drive's rate limits come back as 403 rather than 429, told
    /// apart only by the reason in the body.
    static func isRateLimited(_ status: Int, _ data: Data) -> Bool {
        guard status == 403 else { return false }
        let reasons = ((CloudJSON.object(data)?["error"] as? [String: Any])?["errors"] as? [[String: Any]] ?? [])
            .compactMap { $0["reason"] as? String }
        return reasons.contains("rateLimitExceeded") || reasons.contains("userRateLimitExceeded")
    }

    private func check(
        _ response: HTTPURLResponse, data: Data, path: String, operation: String, destination: String? = nil
    ) throws {
        guard !(200...299).contains(response.statusCode) else { return }
        let error = CloudJSON.object(data)?["error"] as? [String: Any]
        let message = error?["message"] as? String ?? String(decoding: data.prefix(300), as: UTF8.self)
        let reasons = (error?["errors"] as? [[String: Any]] ?? []).compactMap { $0["reason"] as? String }
        Self.log.debug("\(operation) \(path) failed: HTTP \(response.statusCode) \(reasons) \(message)")
        switch response.statusCode {
        case 401:
            throw RemoteFileServiceError.authenticationFailed
        case 404:
            throw RemoteFileServiceError.itemNotFound(path: path)
        case 403 where reasons.contains("storageQuotaExceeded"):
            throw RemoteFileServiceError.operationFailed(operation: operation, path: path, underlying: message)
        case 403:
            throw RemoteFileServiceError.permissionDenied(operation: operation, path: path)
        case 409:
            throw RemoteFileServiceError.alreadyExists(path: destination ?? path)
        default:
            throw RemoteFileServiceError.operationFailed(
                operation: operation, path: path, underlying: "HTTP \(response.statusCode) \(message)")
        }
    }
}
