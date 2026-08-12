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
public enum RemoteFileServiceError: Error, Sendable {
    case notConnected
    case connectionFailed(underlying: String)
    case authenticationFailed
    case itemNotFound(path: String)
    case operationFailed(operation: String, path: String, underlying: String)
    case localFileUnreadable(url: URL)
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
        }
    }
}
