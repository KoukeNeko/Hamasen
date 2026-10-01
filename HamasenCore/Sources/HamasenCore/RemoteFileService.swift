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

/// Protocol-agnostic abstraction over a remote file server.
///
/// Both the File Provider extension and the main app depend only on this
/// protocol; SFTP (Phase 1) and FTP (Phase 2) provide interchangeable
/// implementations behind it.
public protocol RemoteFileService: Sendable {
    /// Establishes the connection and authenticates. Calling it again while
    /// connected is a no-op.
    func connect() async throws

    /// Closes the connection. The service may be reconnected afterwards.
    func disconnect() async throws

    /// Whether the session is still usable.
    ///
    /// A connection can go away with nobody watching — the server drops an
    /// idle session, the machine sleeps, the network changes — and only the
    /// next operation finds out, by failing. Asking first is what lets a dead
    /// connection be replaced instead of used and reported.
    var isConnected: Bool { get async }

    /// Lists directory contents (excluding "." and "..").
    func listDirectory(at path: String) async throws -> [RemoteItem]

    /// Lists directory contents with links reported as links, not as what
    /// they point at. For callers that must not follow them — a copy that
    /// would otherwise turn a link into a duplicate of its target, or loop
    /// on a link to an ancestor.
    func listDirectoryWithoutFollowingLinks(at path: String) async throws -> [RemoteItem]

    /// Fetches attributes for a single item.
    func itemInfo(at path: String) async throws -> RemoteItem

    /// Asks the server something that only an answering server can answer,
    /// to tell whether it is reachable again. Throws while it is not.
    func checkReachable() async throws

    /// Downloads a whole file to a local URL (overwriting any existing file).
    ///
    /// `progress` receives the running total of bytes written so far. The
    /// File Provider system cancels a transfer that stops reporting progress,
    /// so an implementation calls it as bytes arrive, not once at the end,
    /// and stops promptly when its task is cancelled.
    func downloadFile(at path: String, to localURL: URL, progress: TransferProgress?) async throws

    /// Downloads a byte range of a file.
    ///
    /// Returns fewer bytes than requested only when the range runs past the
    /// end of the file.
    func downloadRange(at path: String, offset: Int64, length: Int) async throws -> Data

    /// Uploads a local file to the remote path (overwriting any existing file).
    ///
    /// `progress` receives the running total of bytes sent so far, under the
    /// same rules as `downloadFile`.
    func uploadFile(from localURL: URL, to path: String, progress: TransferProgress?) async throws

    func createDirectory(at path: String) async throws

    func deleteFile(at path: String) async throws

    /// Deletes a directory and everything inside it.
    ///
    /// Each protocol does this its own way — WebDAV in a single request, SFTP
    /// by walking the tree — so callers must not impose one protocol's
    /// constraint on the others.
    func deleteDirectory(at path: String) async throws

    /// Moves or renames an item within the same connection.
    func moveItem(from oldPath: String, to newPath: String) async throws

    /// Finds items whose name matches `query`, anywhere below `path`.
    ///
    /// Declared here rather than only in the extension below so the call is
    /// dispatched dynamically: the default walks, and a protocol that can do
    /// better replaces it. Written the other way, S3's version would never be
    /// reached through the protocol.
    ///
    /// Returning fewer than exist is expected. No protocol here has a search
    /// call, so the default visits directories one by one, and the caller's
    /// limit is what stops it.
    func searchItems(matching query: String, under path: String, limit: Int) async throws -> [RemoteItem]
}

/// Running total of bytes a transfer has moved so far.
public typealias TransferProgress = @Sendable (_ bytesTransferred: Int64) -> Void

extension RemoteFileService {
    /// The root's attributes, which is a real request for any protocol whose
    /// root lookup is one; those that answer the root without asking
    /// override this.
    public func checkReachable() async throws {
        _ = try await itemInfo(at: RemotePath.root)
    }

    /// Protocols without links list the same either way.
    public func listDirectoryWithoutFollowingLinks(at path: String) async throws -> [RemoteItem] {
        try await listDirectory(at: path)
    }

    public func downloadFile(at path: String, to localURL: URL) async throws {
        try await downloadFile(at: path, to: localURL, progress: nil)
    }

    public func uploadFile(from localURL: URL, to path: String) async throws {
        try await uploadFile(from: localURL, to: path, progress: nil)
    }

    /// Visits directories breadth-first, nearest first, until the limit is
    /// reached or there is nothing left.
    ///
    /// Breadth-first because a match beside what the user is looking at is
    /// worth more than one twenty levels down, and because a depth-first walk
    /// of a deep tree spends its whole budget in the first branch.
    ///
    /// Cancellation is not an optimisation here. The system starts a new
    /// query on every keystroke, so a walk that ignored it would leave one
    /// request in flight per character typed.
    public func searchItems(
        matching query: String, under path: String, limit: Int
    ) async throws -> [RemoteItem] {
        /// A walk that never stopped would keep costing requests long after
        /// the user gave up reading the results.
        let maximumDirectories = 200

        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, limit > 0 else { return [] }

        var found: [RemoteItem] = []
        var queue = [path]
        var visited = 0

        while !queue.isEmpty, found.count < limit, visited < maximumDirectories {
            try Task.checkCancellation()
            let directory = queue.removeFirst()
            visited += 1

            // A directory that cannot be read stops that branch, not the
            // search: one folder the account may not enter is not a reason to
            // report nothing at all.
            guard let items = try? await listDirectory(at: directory) else { continue }

            for item in items {
                if item.name.localizedStandardContains(query) {
                    found.append(item)
                    if found.count == limit { break }
                }
                // A link to a folder is a match like any other item, but not a
                // place to search: one to an ancestor never ends.
                if item.isDirectory, !item.isResolvedLink { queue.append(item.path) }
            }
        }
        return found
    }
}

/// Shared error type for RemoteFileService implementations so upper layers
/// can map failures consistently.
public enum RemoteFileServiceError: Error, Equatable, Sendable {
    case notConnected
    case connectionFailed(underlying: String)
    case authenticationFailed
    case itemNotFound(path: String)
    case operationFailed(operation: String, path: String, underlying: String)
    /// The server refused the operation for this account. Retrying will not
    /// help until something changes on the server.
    case permissionDenied(operation: String, path: String)
    /// Something already exists where the operation would have put an item.
    case alreadyExists(path: String)
    case localFileUnreadable(url: URL)
    /// The stored private key is encrypted but no passphrase was supplied.
    case privateKeyPassphraseRequired
    /// The private key could not be decoded — usually a wrong passphrase.
    case privateKeyUnreadable(underlying: String)
    /// The stored credentials are of a kind this protocol cannot use.
    case unsupportedCredentials(protocolName: String)
    /// The server presented a different host key from the one recorded for
    /// it. Either it was rebuilt or something is answering in its place, and
    /// the two cannot be told apart from here.
    case hostKeyChanged(endpoint: String, recorded: String, presented: String)
    /// The record of known host keys could not be read, so the server's
    /// identity could not be checked at all.
    case hostKeyUnverifiable(reason: String)
}

extension RemoteFileServiceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return String(localized: "尚未連線到伺服器", bundle: .module)
        case .connectionFailed(let underlying):
            if underlying.isEmpty { return String(localized: "無法連線到伺服器", bundle: .module) }
            return String(localized: "無法連線到伺服器：\(underlying)", bundle: .module)
        case .authenticationFailed:
            return String(localized: "認證失敗，請檢查帳號與密碼", bundle: .module)
        case .itemNotFound(let path):
            return String(localized: "找不到遠端項目：\(path)", bundle: .module)
        case .operationFailed(let operation, let path, let underlying):
            return String(localized: "\(operation) 失敗（\(path)）：\(underlying)", bundle: .module)
        case .permissionDenied(let operation, let path):
            return String(localized: "\(operation) 失敗（\(path)）：沒有權限", bundle: .module)
        case .alreadyExists(let path):
            return String(localized: "遠端已經有同名項目：\(path)", bundle: .module)
        case .localFileUnreadable(let url):
            return String(localized: "無法讀取本地檔案：\(url.path)", bundle: .module)
        case .privateKeyPassphraseRequired:
            return String(localized: "這把 SSH 金鑰有密碼保護，請輸入金鑰密碼", bundle: .module)
        case .privateKeyUnreadable(let underlying):
            return String(localized: "無法讀取 SSH 金鑰（金鑰密碼可能有誤）：\(underlying)", bundle: .module)
        case .unsupportedCredentials(let protocolName):
            return String(localized: "\(protocolName) 不支援 SSH 金鑰認證，請改用密碼", bundle: .module)
        case .hostKeyChanged(let endpoint, let recorded, let presented):
            // One line, because the catalog is generated by matching this
            // call shape: a literal on the next line is not extracted, and a
            // key that is never extracted silently falls back to Chinese.
            return String(localized: "\(endpoint) 的主機金鑰和上次不同，連線已中止。可能是伺服器重建過，也可能有人冒充它。核對伺服器端的指紋後，到該伺服器的設定中清除已記錄的金鑰。已記錄：\(recorded)，這次收到：\(presented)", bundle: .module)
        case .hostKeyUnverifiable(let reason):
            return String(localized: "無法確認伺服器身分，連線已中止：\(reason)", bundle: .module)
        }
    }
}
