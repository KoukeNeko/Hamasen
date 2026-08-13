import Foundation

/// Re-applies credentials across redirects.
///
/// URLSession drops the Authorization header when it follows a redirect, so a
/// server that merely normalises a collection URL would answer 401 and the
/// user would be told their password is wrong. Credentials are restored only
/// when the redirect stays on the configured host, so they are never handed to
/// a different server.
private final class RedirectAuthenticator: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let authorization: String?
    private let expectedHost: String

    init(authorization: String?, expectedHost: String) {
        self.authorization = authorization
        self.expectedHost = expectedHost
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var request = request
        if let authorization,
           request.value(forHTTPHeaderField: "Authorization") == nil,
           request.url?.host?.caseInsensitiveCompare(expectedHost) == .orderedSame {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        completionHandler(request)
    }
}

/// WebDAV implementation of RemoteFileService, built on URLSession.
///
/// WebDAV is stateless, so there is no connection to hold open: `connect()`
/// verifies the server answers and the credentials are accepted, and every
/// later call is an independent request.
public actor WebDAVFileService: RemoteFileService {
    private enum Method: String {
        case propfind = "PROPFIND"
        case get = "GET"
        case put = "PUT"
        case mkcol = "MKCOL"
        case delete = "DELETE"
        case move = "MOVE"
    }

    /// PROPFIND scope: the item alone, or the item plus its children.
    private enum Depth: String {
        case itemOnly = "0"
        case immediateChildren = "1"
    }

    /// Status codes the responses are classified by.
    private enum Status {
        static let successRange = 200...299
        /// The server ignored a Range header and sent the whole entity.
        static let fullContent = 200
        static let unauthorized = 401
        static let forbidden = 403
        static let notFound = 404
    }

    /// MOVE replaces an existing destination rather than failing.
    private static let overwriteDestination = "T"

    /// Only the properties the app maps onto NSFileProviderItem.
    private static let propfindBody = Data("""
    <?xml version="1.0" encoding="utf-8"?>
    <D:propfind xmlns:D="DAV:">
      <D:prop>
        <D:resourcetype/>
        <D:getcontentlength/>
        <D:getlastmodified/>
      </D:prop>
    </D:propfind>
    """.utf8)

    private static let log = HamasenLog(category: "webdav")

    private let config: ServerConfig
    private let credentials: ServerCredentials
    private let connectTimeoutSeconds: Int
    private var session: URLSession?

    public init(
        config: ServerConfig,
        credentials: ServerCredentials,
        connectTimeoutSeconds: Int = AppSettings.defaultConnectTimeoutSeconds
    ) {
        self.config = config
        self.credentials = credentials
        self.connectTimeoutSeconds = connectTimeoutSeconds
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = TimeInterval(connectTimeoutSeconds)
        configuration.httpShouldSetCookies = false
        // A file provider must never serve a cached body: the system asks for
        // contents precisely when it believes the item changed.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData

        return URLSession(
            configuration: configuration,
            delegate: RedirectAuthenticator(
                authorization: authorizationHeader,
                expectedHost: config.host
            ),
            delegateQueue: nil
        )
    }

    private func activeSession() throws -> URLSession {
        guard let session else { throw RemoteFileServiceError.notConnected }
        return session
    }

    /// The preemptive Basic header, or nil when the stored credentials are not
    /// usable over HTTP.
    private var authorizationHeader: String? {
        guard case .password(let password) = credentials else { return nil }
        let pair = Data("\(config.username):\(password)".utf8).base64EncodedString()
        return "Basic \(pair)"
    }

    // MARK: - Connection lifecycle

    public func connect() async throws {
        guard session == nil else { return }
        Self.log.debug("Checking \(config.host):\(config.port) as \(config.username)")
        session = makeSession()
        do {
            // A depth-0 PROPFIND on the mount root is the cheapest request
            // that proves both reachability and credentials.
            _ = try await propfind(at: RemotePath.root, depth: .itemOnly)
        } catch {
            // Leave the service disconnected rather than holding a session
            // that was never usable.
            session?.invalidateAndCancel()
            session = nil
            throw error
        }
    }

    public func disconnect() async throws {
        let session = self.session
        self.session = nil
        // Let in-flight work finish: cancelling outright turns a racing
        // request into an uncatchable "task created in an invalidated
        // session" exception.
        session?.finishTasksAndInvalidate()
    }

    // MARK: - RemoteFileService

    public func listDirectory(at path: String) async throws -> [RemoteItem] {
        let entries = try await propfind(at: path, depth: .immediateChildren)
        let directoryPath = RemotePath.withoutTrailingSeparator(path)

        return try entries.compactMap { entry in
            let entryPath = try mountRelativePath(fromHref: entry.href)
            // The first entry of a depth-1 PROPFIND is the directory itself.
            guard RemotePath.withoutTrailingSeparator(entryPath) != directoryPath else { return nil }
            return Self.makeRemoteItem(path: entryPath, entry: entry)
        }
    }

    public func itemInfo(at path: String) async throws -> RemoteItem {
        let entries = try await propfind(at: path, depth: .itemOnly)
        guard let entry = entries.first else {
            throw RemoteFileServiceError.itemNotFound(path: path)
        }
        return Self.makeRemoteItem(path: path, entry: entry)
    }

    public func downloadFile(at path: String, to localURL: URL) async throws {
        let request = try makeRequest(method: .get, path: path)
        do {
            // Downloads land in a file rather than memory, so size is bounded
            // by disk rather than RAM.
            let (temporaryURL, response) = try await activeSession().download(for: request)
            // The body file is the system's to clean up only once it has been
            // moved; an error response leaves it behind otherwise.
            do {
                try Self.validate(response, operation: "下載", path: path)
            } catch {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw error
            }
            try? FileManager.default.removeItem(at: localURL)
            try FileManager.default.moveItem(at: temporaryURL, to: localURL)
        } catch {
            throw Self.mapTransportError(error, operation: "下載", path: path)
        }
    }

    public func downloadRange(at path: String, offset: Int64, length: Int) async throws -> Data {
        guard length > 0 else { return Data() }

        var request = try makeRequest(method: .get, path: path)
        let lastByte = offset + Int64(length) - 1
        request.setValue("bytes=\(offset)-\(lastByte)", forHTTPHeaderField: "Range")
        // Without this a server may range the *compressed* entity; URLSession
        // then transparently decompresses and the bytes no longer correspond
        // to the offsets that were asked for.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let bodyURL: URL
        let response: URLResponse
        do {
            // Streamed to disk: a server that ignores Range answers with the
            // whole file, which must not be buffered in memory.
            (bodyURL, response) = try await activeSession().download(for: request)
        } catch {
            throw Self.mapTransportError(error, operation: "下載區間", path: path)
        }
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteFileServiceError.operationFailed(
                operation: "下載區間", path: path, underlying: "非 HTTP 回應"
            )
        }
        // 206 means the range was honoured; 200 means the server sent the
        // whole entity, so the wanted slice is read back out of the file.
        let sliceOffset = httpResponse.statusCode == Status.fullContent ? offset : 0
        if httpResponse.statusCode != Status.fullContent {
            try Self.validate(response, operation: "下載區間", path: path)
        }
        return try Self.readSlice(from: bodyURL, offset: sliceOffset, length: length, path: path)
    }

    public func uploadFile(from localURL: URL, to path: String) async throws {
        let request = try makeRequest(method: .put, path: path)
        do {
            let (_, response) = try await activeSession().upload(for: request, fromFile: localURL)
            try Self.validate(response, operation: "上傳", path: path)
        } catch {
            throw Self.mapTransportError(error, operation: "上傳", path: path)
        }
    }

    public func createDirectory(at path: String) async throws {
        try await perform(method: .mkcol, path: path, operation: "建立目錄")
    }

    public func deleteFile(at path: String) async throws {
        try await perform(method: .delete, path: path, operation: "刪除檔案")
    }

    public func deleteDirectory(at path: String) async throws {
        try await perform(method: .delete, path: path, operation: "刪除目錄")
    }

    public func moveItem(from oldPath: String, to newPath: String) async throws {
        var request = try makeRequest(method: .move, path: oldPath)
        request.setValue(try absoluteURL(for: newPath).absoluteString, forHTTPHeaderField: "Destination")
        request.setValue(Self.overwriteDestination, forHTTPHeaderField: "Overwrite")
        try await send(request, operation: "移動", path: oldPath)
    }

    // MARK: - Requests

    private func propfind(at path: String, depth: Depth) async throws -> [PropfindResponseParser.Entry] {
        var request = try makeRequest(method: .propfind, path: path)
        request.setValue(depth.rawValue, forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.propfindBody

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await activeSession().data(for: request)
        } catch {
            throw Self.mapTransportError(error, operation: "列出目錄", path: path)
        }
        try Self.validate(response, operation: "列出目錄", path: path)

        do {
            return try PropfindResponseParser.parse(data)
        } catch {
            throw RemoteFileServiceError.operationFailed(
                operation: "列出目錄", path: path, underlying: String(describing: error)
            )
        }
    }

    private func perform(method: Method, path: String, operation: String) async throws {
        try await send(try makeRequest(method: method, path: path), operation: operation, path: path)
    }

    private func send(_ request: URLRequest, operation: String, path: String) async throws {
        do {
            let (_, response) = try await activeSession().data(for: request)
            try Self.validate(response, operation: operation, path: path)
        } catch {
            throw Self.mapTransportError(error, operation: operation, path: path)
        }
    }

    private func makeRequest(method: Method, path: String) throws -> URLRequest {
        var request = URLRequest(url: try absoluteURL(for: path))
        request.httpMethod = method.rawValue

        // Basic credentials are sent up front: WebDAV servers commonly reject
        // an unauthenticated probe outright rather than challenging.
        guard let authorizationHeader else {
            // Sending the request unauthenticated would surface as a plain 401
            // and send the user looking for a wrong password.
            throw RemoteFileServiceError.unsupportedCredentials(
                protocolName: config.transferProtocol.displayName
            )
        }
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        return request
    }

    /// Builds the absolute URL of a mount-relative path.
    private func absoluteURL(for mountRelativePath: String) throws -> URL {
        var components = URLComponents()
        components.scheme = config.transferProtocol.urlScheme
        components.host = Self.urlHost(for: config.host)
        if config.port != config.transferProtocol.defaultPort {
            components.port = config.port
        }
        components.path = RemotePath.resolve(mountRelativePath, against: config.remotePath)

        guard let url = components.url else {
            throw RemoteFileServiceError.operationFailed(
                operation: "組合網址", path: mountRelativePath, underlying: "無效的主機或路徑"
            )
        }
        return url
    }

    /// Converts an href from the server back into a mount-relative path.
    private func mountRelativePath(fromHref href: String) throws -> String {
        let serverPath = PropfindResponseParser.path(fromHref: href)
        let base = config.remotePath
        guard base != RemotePath.root else { return serverPath }
        guard serverPath.hasPrefix(base) else {
            // Treating a foreign href as mount-relative would make the folder
            // appear inside itself and send later requests to a wrong path.
            throw RemoteFileServiceError.operationFailed(
                operation: "解析回應", path: serverPath,
                underlying: "伺服器回傳的路徑不在掛載範圍內"
            )
        }
        let stripped = String(serverPath.dropFirst(base.count))
        return stripped.isEmpty ? RemotePath.root : stripped
    }

    // MARK: - Responses

    /// Reads a byte range back out of a downloaded body file.
    private static func readSlice(
        from url: URL,
        offset: Int64,
        length: Int,
        path: String
    ) throws -> Data {
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            try file.seek(toOffset: UInt64(max(offset, 0)))
            return try file.read(upToCount: length) ?? Data()
        } catch {
            throw RemoteFileServiceError.operationFailed(
                operation: "下載區間", path: path, underlying: error.localizedDescription
            )
        }
    }

    /// URLComponents rejects a bare IPv6 literal; it has to be bracketed.
    private static func urlHost(for host: String) -> String {
        guard host.contains(":"), !host.hasPrefix("[") else { return host }
        return "[\(host)]"
    }

    private static func makeRemoteItem(path: String, entry: PropfindResponseParser.Entry) -> RemoteItem {
        RemoteItem(
            path: path,
            name: RemotePath.name(of: path),
            kind: entry.isCollection ? .directory : .file,
            size: entry.contentLength,
            modificationDate: entry.lastModified
        )
    }

    private static func validate(_ response: URLResponse, operation: String, path: String) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteFileServiceError.operationFailed(
                operation: operation, path: path, underlying: "非 HTTP 回應"
            )
        }
        switch httpResponse.statusCode {
        case Status.successRange:
            return
        case Status.unauthorized, Status.forbidden:
            log.error("\(operation) at \(path) rejected: HTTP \(httpResponse.statusCode)")
            throw RemoteFileServiceError.authenticationFailed
        case Status.notFound:
            log.debug("\(operation) at \(path): not found")
            throw RemoteFileServiceError.itemNotFound(path: path)
        default:
            log.error("\(operation) at \(path) failed: HTTP \(httpResponse.statusCode)")
            throw RemoteFileServiceError.operationFailed(
                operation: operation, path: path, underlying: "HTTP \(httpResponse.statusCode)"
            )
        }
    }

    private static func mapTransportError(_ error: Error, operation: String, path: String) -> Error {
        // A domain error keeps its identity: wrapping it would hide cases the
        // File Provider layer maps onto specific system errors.
        if let domainError = error as? RemoteFileServiceError { return domainError }

        let urlError = error as? URLError
        switch urlError?.code {
        case .cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost, .notConnectedToInternet:
            log.error("\(operation) at \(path) unreachable: \(String(describing: error))")
            return RemoteFileServiceError.connectionFailed(underlying: error.localizedDescription)
        case .userAuthenticationRequired:
            return RemoteFileServiceError.authenticationFailed
        case .appTransportSecurityRequiresSecureConnection:
            // Cleartext HTTP is only permitted to the local network, so a
            // public hostname needs the HTTPS variant of the protocol.
            log.error("\(operation) at \(path) blocked by App Transport Security")
            return RemoteFileServiceError.connectionFailed(
                underlying: "系統要求加密連線，請改用 WebDAV (HTTPS)"
            )
        default:
            log.error("\(operation) at \(path) failed: \(String(describing: error))")
            return RemoteFileServiceError.operationFailed(
                operation: operation, path: path, underlying: error.localizedDescription
            )
        }
    }
}
