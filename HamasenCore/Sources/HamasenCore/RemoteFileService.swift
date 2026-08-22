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

    /// Fetches attributes for a single item.
    func itemInfo(at path: String) async throws -> RemoteItem

    /// Downloads a whole file to a local URL (overwriting any existing file).
    func downloadFile(at path: String, to localURL: URL) async throws

    /// Downloads a byte range of a file.
    ///
    /// Returns fewer bytes than requested only when the range runs past the
    /// end of the file.
    func downloadRange(at path: String, offset: Int64, length: Int) async throws -> Data

    /// Uploads a local file to the remote path (overwriting any existing file).
    func uploadFile(from localURL: URL, to path: String) async throws

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
}

/// Shared error type for RemoteFileService implementations so upper layers
/// can map failures consistently.
public enum RemoteFileServiceError: Error, Equatable, Sendable {
    case notConnected
    case connectionFailed(underlying: String)
    case authenticationFailed
    case itemNotFound(path: String)
    case operationFailed(operation: String, path: String, underlying: String)
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
            return String(localized: "無法連線到伺服器：\(underlying)", bundle: .module)
        case .authenticationFailed:
            return String(localized: "認證失敗，請檢查帳號與密碼", bundle: .module)
        case .itemNotFound(let path):
            return String(localized: "找不到遠端項目：\(path)", bundle: .module)
        case .operationFailed(let operation, let path, let underlying):
            return String(localized: "\(operation) 失敗（\(path)）：\(underlying)", bundle: .module)
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
