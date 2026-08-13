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

    /// Deletes a directory (must be empty; recursive deletion is the caller's
    /// responsibility).
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
}

extension RemoteFileServiceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "尚未連線到伺服器"
        case .connectionFailed(let underlying):
            return "無法連線到伺服器：\(underlying)"
        case .authenticationFailed:
            return "認證失敗，請檢查帳號與密碼"
        case .itemNotFound(let path):
            return "找不到遠端項目：\(path)"
        case .operationFailed(let operation, let path, let underlying):
            return "\(operation) 失敗（\(path)）：\(underlying)"
        case .localFileUnreadable(let url):
            return "無法讀取本地檔案：\(url.path)"
        case .privateKeyPassphraseRequired:
            return "這把 SSH 金鑰有密碼保護，請輸入金鑰密碼"
        case .privateKeyUnreadable(let underlying):
            return "無法讀取 SSH 金鑰（金鑰密碼可能有誤）：\(underlying)"
        case .unsupportedCredentials(let protocolName):
            return "\(protocolName) 不支援 SSH 金鑰認證，請改用密碼"
        }
    }
}
