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
import Security

/// Keeps credentials attached across redirects, but only when the redirect
/// stays on the same origin and the method is safe to replay.
///
/// URLSession strips the Authorization header whenever the origin changes, so
/// a server that merely normalises a collection URL would answer 401 and the
/// user would be told their password is wrong. Restoring it requires care:
/// the header must never travel to a different scheme, host, or port, and a
/// redirect must never be followed for a method whose body Foundation does
/// not carry across — a redirected PUT would otherwise store an empty file.
private final class RedirectAuthenticator: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    /// Methods whose redirect can be followed safely: they carry no body and
    /// re-issuing them has no side effect.
    private static let replayableMethods: Set<String> = ["GET", "HEAD", "PROPFIND"]

    private let authorization: String?
    private let origin: URLComponents
    /// Certificate authorities trusted in place of the system's, for tests
    /// that serve HTTPS under one of their own. Empty in the app.
    private let trustedAnchors: [SecCertificate]

    init(authorization: String?, scheme: String?, host: String, port: Int, trustedAnchors: [SecCertificate] = []) {
        self.authorization = authorization
        self.trustedAnchors = trustedAnchors
        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host
        origin.port = port
        self.origin = origin
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let method = task.originalRequest?.httpMethod ?? request.httpMethod ?? ""
        guard Self.replayableMethods.contains(method) else {
            // Refusing the redirect surfaces the 3xx to validate() as a plain
            // failure, which is far better than a PUT that silently uploads
            // nothing.
            completionHandler(nil)
            return
        }

        var request = request
        if let authorization,
           request.value(forHTTPHeaderField: "Authorization") == nil,
           isSameOrigin(request.url) {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard !trustedAnchors.isEmpty,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else { return (.performDefaultHandling, nil) }
        SecTrustSetAnchorCertificates(trust, trustedAnchors as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }

    /// Scheme, host and port must all match: a same-host redirect from https
    /// to http would otherwise put the password on the wire in the clear.
    private func isSameOrigin(_ url: URL?) -> Bool {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        let port = components.port ?? Self.defaultPort(forScheme: components.scheme)
        return components.scheme?.caseInsensitiveCompare(origin.scheme ?? "") == .orderedSame
            && components.host?.caseInsensitiveCompare(origin.host ?? "") == .orderedSame
            && port == origin.port
    }

    private static func defaultPort(forScheme scheme: String?) -> Int? {
        switch scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
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
        case head = "HEAD"
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

    private enum Status {
        static let successRange = 200...299
        /// The server ignored a Range header and sent the whole entity.
        static let fullContent = 200
        static let partialContent = 206
        /// Per-member results; success only where the body is parsed.
        static let multiStatus = 207
        static let unauthorized = 401
        static let forbidden = 403
        static let notFound = 404
        /// MKCOL's answer for a name already taken.
        static let methodNotAllowed = 405
        static let preconditionFailed = 412
        static let rangeNotSatisfiable = 416
    }

    /// MOVE must fail rather than replace an existing destination, matching
    /// SFTP's rename and letting Finder offer its own replace prompt.
    private static let refuseOverwrite = "F"
    /// Except for the MOVE that puts a finished upload in place, which is
    /// the replacing the caller asked for.
    private static let allowOverwrite = "T"

    /// Only the properties the app maps onto NSFileProviderItem.
    private static let propfindBody = Data("""
    <?xml version="1.0" encoding="utf-8"?>
    <D:propfind xmlns:D="DAV:">
      <D:prop>
        <D:resourcetype/>
        <D:getcontentlength/>
        <D:getlastmodified/>
        <D:getetag/>
      </D:prop>
    </D:propfind>
    """.utf8)

    /// Declared on every PROPFIND answer by Nextcloud, ownCloud and
    /// ownCloud Infinite Scale; see `uploadsInPlace`.
    private static let ownCloudNamespace = Data("http://owncloud.org/ns".utf8)

    private static let listOperation = "列出目錄"

    private static let log = HamasenLog(category: "webdav")

    /// A whole entity downloaded because the server ignored a Range request,
    /// kept so the remaining chunks of one file do not re-download it.
    private struct CachedBody {
        let path: String
        /// What the server said identified this content when it was sent; the
        /// copy is served only while the server still says the same.
        let validator: String
        let url: URL
    }

    private let config: ServerConfig
    private let credentials: ServerCredentials
    private let connectTimeoutSeconds: Int
    private let authorizationHeader: String?

    private var session: URLSession?
    /// Requests that have been handed a session but have not finished. The
    /// session must not be invalidated while any of them exist: URLSession
    /// raises an uncatchable ObjC exception if a task is created on an
    /// invalidated session, and that window is open across every await.
    private var requestsInFlight = 0
    private var isTearingDown = false
    private var cachedBody: CachedBody?
    /// Whether uploads are PUT straight to their name. Nextcloud and
    /// ownCloud delete the file a MOVE lands on before moving, and with it
    /// the file id that its versions, shares, public links, comments and
    /// tags hang on; they hold a PUT in a part file of their own until it is
    /// complete, so writing to the name is safe there.
    ///
    /// Told apart by the ownCloud namespace in the connect probe's answer,
    /// at no cost in requests. Nextcloud, ownCloud and Infinite Scale declare
    /// it on every multistatus whether or not any of its properties were
    /// asked for — sabre writes out the whole namespace map their file
    /// plugins add it to, and Infinite Scale writes it as a fixed attribute —
    /// while the probe asks only for DAV: properties, so no other server has
    /// cause to name it. The headers that mark these servers (OC-FileId,
    /// OC-ETag) only arrive on the PUT and MOVE being chosen between, and a
    /// proxy can put the /remote.php/ endpoint behind any path.
    private var uploadsInPlace = false

    private let trustedAnchors: [SecCertificate]

    public init(
        config: ServerConfig,
        credentials: ServerCredentials,
        connectTimeoutSeconds: Int = AppSettings.defaultConnectTimeoutSeconds
    ) {
        self.init(
            config: config, credentials: credentials, connectTimeoutSeconds: connectTimeoutSeconds,
            trustedAnchors: [])
    }

    /// - Parameter trustedAnchors: certificate authorities trusted in place
    ///   of the system's, for tests that serve HTTPS under their own.
    init(
        config: ServerConfig,
        credentials: ServerCredentials,
        connectTimeoutSeconds: Int,
        trustedAnchors: [SecCertificate]
    ) {
        self.config = config
        self.credentials = credentials
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.trustedAnchors = trustedAnchors

        if case .password(let password) = credentials {
            let pair = Data("\(config.username):\(password)".utf8).base64EncodedString()
            self.authorizationHeader = "Basic \(pair)"
        } else {
            self.authorizationHeader = nil
        }
    }

    // MARK: - Connection lifecycle

    public func connect() async throws {
        guard session == nil, !isTearingDown else { return }
        guard authorizationHeader != nil else {
            throw RemoteFileServiceError.unsupportedCredentials(
                protocolName: config.transferProtocol.displayName
            )
        }
        Self.log.debug("Checking \(config.host):\(config.port) as \(config.username)")

        // Probed on a session that is not published yet, so a concurrent
        // connect() cannot observe success before the credentials are checked.
        let candidate = makeSession()
        do {
            let document = try await propfindDocument(at: RemotePath.root, depth: .itemOnly, using: candidate)
            _ = try Self.parseMultiStatus(document, path: RemotePath.root)
            uploadsInPlace = document.range(of: Self.ownCloudNamespace) != nil
        } catch {
            candidate.invalidateAndCancel()
            throw error
        }
        session = candidate
    }

    /// HTTP keeps no session to lose, so this only reports whether the
    /// service has been connected and not torn down.
    public var isConnected: Bool {
        session != nil && !isTearingDown
    }

    public func disconnect() async throws {
        isTearingDown = true
        discardCachedBody()
        tearDownSessionIfIdle()
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
                scheme: config.transferProtocol.urlScheme,
                host: config.host,
                port: config.port,
                trustedAnchors: trustedAnchors
            ),
            delegateQueue: nil
        )
    }

    /// Runs one request against the live session, holding it open for the
    /// duration so a concurrent disconnect() cannot invalidate it mid-flight.
    private func withSession<T>(_ work: (URLSession) async throws -> T) async throws -> T {
        guard let session, !isTearingDown else { throw RemoteFileServiceError.notConnected }
        requestsInFlight += 1
        defer {
            requestsInFlight -= 1
            tearDownSessionIfIdle()
        }
        return try await work(session)
    }

    private func tearDownSessionIfIdle() {
        guard isTearingDown, requestsInFlight == 0, let session else { return }
        self.session = nil
        isTearingDown = false
        session.finishTasksAndInvalidate()
    }

    // MARK: - RemoteFileService

    public func listDirectory(at path: String) async throws -> [RemoteItem] {
        let entries = try await propfind(at: path, depth: .immediateChildren)
        let directoryPath = RemotePath.withoutTrailingSeparator(path)

        return entries.compactMap { entry in
            // An href outside the mount is the server disagreeing with us
            // about the base path; dropping that one entry degrades the
            // listing instead of failing the whole directory.
            guard let entryPath = mountRelativePath(fromHref: entry.href) else {
                Self.log.error("Ignoring href outside the mount: \(entry.href)")
                return nil
            }
            // A depth-1 PROPFIND also describes the directory itself; it is
            // matched by path rather than position, which servers vary on.
            guard RemotePath.withoutTrailingSeparator(entryPath) != directoryPath else { return nil }
            // Uploads in flight are not part of the folder yet.
            guard !RemotePath.isTemporaryUpload(name: RemotePath.name(of: entryPath)) else { return nil }
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

    public func downloadFile(at path: String, to localURL: URL, progress: TransferProgress?) async throws {
        let request = try makeRequest(method: .get, path: path)
        let (temporaryURL, response) = try await withSession { session in
            do {
                return try await session.download(
                    for: request, delegate: Self.progressDelegate(progress, session: session))
            } catch {
                throw Self.mapTransportError(error, operation: String(localized: "下載", bundle: .module), path: path)
            }
        }
        // The downloaded body is ours to clean up until it has been moved.
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        try Self.validate(response, method: .get, operation: String(localized: "下載", bundle: .module), path: path)
        try? FileManager.default.removeItem(at: localURL)
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: localURL)
        } catch {
            throw RemoteFileServiceError.localFileUnreadable(url: localURL)
        }
        // The delegate reports bytes as they arrive, but not reliably the
        // last of them: the call can return before its final callback. The
        // total is known now, so it is reported here whatever came before.
        if let progress, let size = try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            progress(Int64(size))
        }
    }

    public func downloadRange(at path: String, offset: Int64, length: Int) async throws -> Data {
        guard length > 0 else { return Data() }

        // A server that already answered a whole entity for this file keeps
        // answering whole entities; serving later chunks from the copy on
        // disk avoids re-downloading the file once per chunk.
        if let cached = cachedBody, cached.path == path {
            if await currentValidator(at: path) == cached.validator {
                return try Self.readSlice(from: cached.url, offset: offset, length: length, path: path)
            }
            // The file changed on the server, or cannot be checked: slices of
            // the old copy would be served as if they were the new content.
            discardCachedBody(forPath: path)
        }

        var request = try makeRequest(method: .get, path: path)
        let lastByte = offset + Int64(length) - 1
        request.setValue("bytes=\(offset)-\(lastByte)", forHTTPHeaderField: "Range")
        // Without this a server may range the *compressed* entity; URLSession
        // then transparently decompresses and the bytes no longer correspond
        // to the offsets that were asked for.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let (bodyURL, response) = try await withSession { session in
            do {
                // Streamed to disk: a server that ignores Range answers with
                // the whole file, which must not be buffered in memory.
                return try await session.download(for: request)
            } catch {
                throw Self.mapTransportError(error, operation: String(localized: "下載區間", bundle: .module), path: path)
            }
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: bodyURL)
            throw RemoteFileServiceError.operationFailed(
                operation: String(localized: "下載區間", bundle: .module), path: path, underlying: "非 HTTP 回應"
            )
        }

        // Reading past the end of a file is a short read, not an error: the
        // protocol contract matches SFTP, which simply returns fewer bytes.
        if httpResponse.statusCode == Status.rangeNotSatisfiable {
            try? FileManager.default.removeItem(at: bodyURL)
            return Data()
        }

        switch httpResponse.statusCode {
        case Status.fullContent:
            // The server ignored the Range header. Keep the body so the rest
            // of this file costs nothing more.
            let sliced = try Self.readSlice(from: bodyURL, offset: offset, length: length, path: path)
            retainCachedBody(at: bodyURL, path: path, response: httpResponse)
            return sliced
        case Status.partialContent:
            defer { try? FileManager.default.removeItem(at: bodyURL) }
            // The body starts wherever Content-Range says, which is not
            // necessarily the offset that was requested.
            guard let start = Self.contentRangeStart(httpResponse) else {
                throw RemoteFileServiceError.operationFailed(
                    operation: String(localized: "下載區間", bundle: .module), path: path, underlying: "206 回應缺少 Content-Range"
                )
            }
            let skip = offset - start
            guard skip >= 0 else {
                throw RemoteFileServiceError.operationFailed(
                    operation: String(localized: "下載區間", bundle: .module), path: path, underlying: "伺服器回傳的區間起點不符"
                )
            }
            return try Self.readSlice(from: bodyURL, offset: skip, length: length, path: path)
        default:
            defer { try? FileManager.default.removeItem(at: bodyURL) }
            try Self.validate(response, method: .get, operation: String(localized: "下載區間", bundle: .module), path: path)
            throw RemoteFileServiceError.operationFailed(
                operation: String(localized: "下載區間", bundle: .module), path: path, underlying: "HTTP \(httpResponse.statusCode)"
            )
        }
    }

    /// Written beside the file and moved over it once complete, except on
    /// Nextcloud and ownCloud (see `uploadsInPlace`). Servers such as rclone
    /// keep whatever arrived of a PUT that was cut off, under the name it
    /// was sent to, so a connection lost halfway through a PUT to the real
    /// name leaves half of the new file where the old one was.
    public func uploadFile(from localURL: URL, to path: String, progress: TransferProgress?) async throws {
        let operation = String(localized: "上傳", bundle: .module)
        let temporaryPath = uploadsInPlace ? nil : RemotePath.temporaryUploadPath(for: path)
        var isMoving = false
        do {
            let request = try makeRequest(method: .put, path: temporaryPath ?? path)
            let (body, response) = try await withSession { session in
                do {
                    return try await session.upload(
                        for: request, fromFile: localURL,
                        delegate: Self.progressDelegate(progress, session: session))
                } catch {
                    throw Self.mapTransportError(error, operation: operation, path: path)
                }
            }
            try Self.validate(response, body: body, method: .put, operation: operation, path: path)
            if let temporaryPath {
                let replacesFile = try await refuseFolder(at: path)
                isMoving = true
                try await moveUpload(
                    from: temporaryPath, to: path, overwriting: replacesFile, operation: operation)
            }
        } catch {
            if let temporaryPath {
                if isMoving {
                    await settleFailedMove(of: temporaryPath, to: path)
                } else {
                    await discardTemporaryUpload(at: temporaryPath)
                }
            }
            throw error
        }
        discardCachedBody(forPath: path)
        if let progress, let size = try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            progress(Int64(size))
        }
    }

    /// MOVE with Overwrite: T deletes whatever is at the destination first,
    /// folder and all, so a folder that appeared under the name while the
    /// upload ran is refused rather than replaced. Returns whether a file is
    /// there to be replaced.
    private func refuseFolder(at path: String) async throws -> Bool {
        do {
            if try await itemInfo(at: path).isDirectory {
                throw RemoteFileServiceError.alreadyExists(path: path)
            }
            return true
        } catch RemoteFileServiceError.itemNotFound {
            return false
        }
    }

    /// - Parameter overwriting: whether a file was at the destination when
    ///   it was looked at. When nothing was, the MOVE refuses to overwrite:
    ///   a file someone else created there since is theirs, and the server
    ///   answers 412 instead of replacing it.
    private func moveUpload(
        from temporaryPath: String, to path: String, overwriting: Bool, operation: String
    ) async throws {
        var request = try makeRequest(method: .move, path: temporaryPath)
        request.setValue(try absoluteURL(for: path).absoluteString, forHTTPHeaderField: "Destination")
        request.setValue(overwriting ? Self.allowOverwrite : Self.refuseOverwrite, forHTTPHeaderField: "Overwrite")
        let (body, response) = try await withSession { session in
            do {
                return try await session.data(for: request)
            } catch {
                throw Self.mapTransportError(error, operation: operation, path: path)
            }
        }
        try Self.validate(response, body: body, method: .move, operation: operation, path: path)
    }

    /// A MOVE can fail after the server has already deleted the destination
    /// — servers that overwrite by deleting first and renaming second do —
    /// and then the upload under its temporary name is the only copy of the
    /// file left. It is removed only once the destination is seen to be there;
    /// otherwise it stays, hidden from listings, and where it is gets logged.
    private func settleFailedMove(of temporaryPath: String, to path: String) async {
        let destinationExists = await Task { (try? await self.itemInfo(at: path)) != nil }.value
        if destinationExists {
            await discardTemporaryUpload(at: temporaryPath)
        } else {
            Self.log.error("upload to \(path) could not be moved into place and nothing is there now; kept at \(temporaryPath)")
        }
    }

    /// Best effort: the upload has already failed, and this only tidies up
    /// after it. Over a connection that is gone it fails as well, and the
    /// listings hide what it leaves.
    ///
    /// Sent from a task of its own, because the upload's may have been
    /// cancelled and URLSession cancels a request made from a cancelled task
    /// before it is sent.
    private func discardTemporaryUpload(at temporaryPath: String) async {
        await Task {
            do {
                try await self.perform(
                    method: .delete, path: temporaryPath, operation: String(localized: "刪除檔案", bundle: .module))
            } catch RemoteFileServiceError.itemNotFound {
            } catch {
                Self.log.notice("could not remove temporary upload \(temporaryPath): \(String(describing: error))")
            }
        }.value
    }

    public func createDirectory(at path: String) async throws {
        let operation = String(localized: "建立目錄", bundle: .module)
        // RFC 4918 refuses an existing name with 405, but some servers —
        // rclone among them — answer 201 and leave it as it was, which would
        // pass an existing folder off as a new one. So the name is looked up
        // first, and 405 still covers one created in between.
        do {
            _ = try await itemInfo(at: path)
            throw RemoteFileServiceError.alreadyExists(path: path)
        } catch RemoteFileServiceError.itemNotFound {
        }
        let request = try makeRequest(method: .mkcol, path: path)
        let (body, response) = try await withSession { session in
            do {
                return try await session.data(for: request)
            } catch {
                throw Self.mapTransportError(error, operation: operation, path: path)
            }
        }
        if (response as? HTTPURLResponse)?.statusCode == Status.methodNotAllowed {
            throw RemoteFileServiceError.alreadyExists(path: path)
        }
        try Self.validate(response, body: body, method: .mkcol, operation: operation, path: path)
    }

    public func deleteFile(at path: String) async throws {
        try await perform(method: .delete, path: path, operation: String(localized: "刪除檔案", bundle: .module))
        discardCachedBody(forPath: path)
    }

    public func deleteDirectory(at path: String) async throws {
        try await perform(method: .delete, path: path, operation: String(localized: "刪除目錄", bundle: .module))
    }

    public func moveItem(from oldPath: String, to newPath: String) async throws {
        var request = try makeRequest(method: .move, path: oldPath)
        request.setValue(try absoluteURL(for: newPath).absoluteString, forHTTPHeaderField: "Destination")
        request.setValue(Self.refuseOverwrite, forHTTPHeaderField: "Overwrite")

        let (body, response) = try await withSession { session in
            do {
                return try await session.data(for: request)
            } catch {
                throw Self.mapTransportError(error, operation: String(localized: "移動", bundle: .module), path: oldPath)
            }
        }
        // Overwrite: F met an existing destination; the name in the way is
        // the destination's, not the source's.
        if (response as? HTTPURLResponse)?.statusCode == Status.preconditionFailed {
            throw RemoteFileServiceError.alreadyExists(path: newPath)
        }
        try Self.validate(response, body: body, method: .move, operation: String(localized: "移動", bundle: .module), path: oldPath)
        discardCachedBody(forPath: oldPath)
    }

    // MARK: - Requests

    private func propfind(at path: String, depth: Depth) async throws -> [PropfindResponseParser.Entry] {
        try Self.parseMultiStatus(await propfindDocument(at: path, depth: depth), path: path)
    }

    /// The multistatus as the server sent it, for connect(), which reads
    /// more of it than the parsed entries carry.
    private func propfindDocument(
        at path: String,
        depth: Depth,
        using probeSession: URLSession? = nil
    ) async throws -> Data {
        var request = try makeRequest(method: .propfind, path: path)
        request.setValue(depth.rawValue, forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.propfindBody

        let operation = Self.listOperation
        let fetch: (URLSession) async throws -> (Data, URLResponse) = { session in
            do {
                return try await session.data(for: request)
            } catch {
                throw Self.mapTransportError(error, operation: operation, path: path)
            }
        }

        let data: Data
        let response: URLResponse
        if let probeSession {
            (data, response) = try await fetch(probeSession)
        } else {
            (data, response) = try await withSession(fetch)
        }
        try Self.validate(response, method: .propfind, operation: operation, path: path)
        return data
    }

    private static func parseMultiStatus(_ document: Data, path: String) throws -> [PropfindResponseParser.Entry] {
        do {
            return try PropfindResponseParser.parse(document)
        } catch {
            throw RemoteFileServiceError.operationFailed(
                operation: listOperation, path: path, underlying: String(describing: error)
            )
        }
    }

    private func perform(method: Method, path: String, operation: String) async throws {
        let request = try makeRequest(method: method, path: path)
        let (body, response) = try await withSession { session in
            do {
                return try await session.data(for: request)
            } catch {
                throw Self.mapTransportError(error, operation: operation, path: path)
            }
        }
        try Self.validate(response, body: body, method: method, operation: operation, path: path)
    }

    private func makeRequest(method: Method, path: String) throws -> URLRequest {
        var request = URLRequest(url: try absoluteURL(for: path))
        request.httpMethod = method.rawValue
        // Basic credentials are sent up front: WebDAV servers commonly reject
        // an unauthenticated probe outright rather than challenging.
        guard let authorizationHeader else {
            throw RemoteFileServiceError.unsupportedCredentials(
                protocolName: config.transferProtocol.displayName
            )
        }
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        return request
    }

    /// Builds the absolute URL of a mount-relative path.
    private func absoluteURL(for mountRelativePath: String) throws -> URL {
        // URLComponents traps rather than throwing on a negative port, so a
        // malformed stored config must be rejected before it gets there.
        guard (1...65535).contains(config.port) else {
            throw RemoteFileServiceError.operationFailed(
                operation: String(localized: "組合網址", bundle: .module), path: mountRelativePath,
                underlying: "無效的連接埠：\(config.port)"
            )
        }

        var components = URLComponents()
        components.scheme = config.transferProtocol.urlScheme
        components.host = Self.urlHost(for: config.host)
        if config.port != config.transferProtocol.defaultPort {
            components.port = config.port
        }
        components.path = RemotePath.resolve(mountRelativePath, against: config.remotePath)

        guard let url = components.url else {
            throw RemoteFileServiceError.operationFailed(
                operation: String(localized: "組合網址", bundle: .module), path: mountRelativePath, underlying: "無效的主機或路徑"
            )
        }
        return url
    }

    /// Converts an href from the server into a mount-relative path, or nil
    /// when it names something outside the mount.
    private func mountRelativePath(fromHref href: String) -> String? {
        let serverPath = PropfindResponseParser.path(fromHref: href)
        let base = config.remotePath
        guard base != RemotePath.root else { return serverPath }
        // Compared case-insensitively and on a path boundary, so "/dav" does
        // not swallow "/davfoo" and a case-normalising server still matches.
        guard serverPath.lowercased() == base.lowercased()
                || serverPath.lowercased().hasPrefix(base.lowercased() + RemotePath.separator)
        else { return nil }

        let stripped = String(serverPath.dropFirst(base.count))
        return stripped.isEmpty ? RemotePath.root : stripped
    }

    // MARK: - Cached whole-entity bodies

    private func retainCachedBody(at url: URL, path: String, response: HTTPURLResponse) {
        // Without a validator there is no way to tell a stale copy from a
        // fresh one, so nothing is kept.
        guard let validator = Self.validator(of: response) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        discardCachedBody()
        cachedBody = CachedBody(path: path, validator: validator, url: url)
    }

    private func discardCachedBody(forPath path: String? = nil) {
        guard let cached = cachedBody else { return }
        if let path, cached.path != path { return }
        try? FileManager.default.removeItem(at: cached.url)
        cachedBody = nil
    }

    /// The server's current validator for the file, or nil when it cannot be
    /// had. A HEAD rather than a PROPFIND, so it is spelled by the same
    /// headers the cached body's was and the two compare exactly.
    private func currentValidator(at path: String) async -> String? {
        // Every failure here means "cannot confirm the copy is current", and
        // the caller then fetches again, where the real error is reported.
        guard var request = try? makeRequest(method: .head, path: path) else { return nil }
        // The same request shape as the ranged GET whose validator this is
        // compared against: a compressed answer can carry a different ETag.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        guard let (_, response) = try? await withSession({ try await $0.data(for: request) }),
              let http = response as? HTTPURLResponse,
              Status.successRange.contains(http.statusCode)
        else { return nil }
        return Self.validator(of: http)
    }

    /// An ETag when the server sends one, otherwise the modification time
    /// with the length, since a time alone cannot tell two edits within a
    /// second apart.
    private static func validator(of response: HTTPURLResponse) -> String? {
        if let tag = HTTPTransfer.normalizedETag(response.value(forHTTPHeaderField: "ETag")) {
            return "etag:\(tag)"
        }
        guard let modified = response.value(forHTTPHeaderField: "Last-Modified") else { return nil }
        let length = response.value(forHTTPHeaderField: "Content-Length") ?? ""
        return "modified:\(modified)|\(length)"
    }

    // MARK: - Responses

    private static func progressDelegate(
        _ progress: TransferProgress?, session: URLSession
    ) -> TransferProgressDelegate? {
        progress.map {
            TransferProgressDelegate(
                redirectHandler: session.delegate as? URLSessionTaskDelegate, progress: $0)
        }
    }

    private static func makeRemoteItem(path: String, entry: PropfindResponseParser.Entry) -> RemoteItem {
        RemoteItem(
            path: path,
            name: RemotePath.name(of: path),
            kind: entry.isCollection ? .directory : .file,
            size: entry.contentLength ?? 0,
            modificationDate: entry.lastModified,
            // A collection's tag changes with its contents on some servers,
            // and a directory has no content of its own to version.
            contentTag: entry.isCollection ? nil : entry.contentTag
        )
    }

    /// The first byte offset a `Content-Range` header describes.
    private static func contentRangeStart(_ response: HTTPURLResponse) -> Int64? {
        guard let header = response.value(forHTTPHeaderField: "Content-Range"),
              let span = header.split(separator: " ").last,
              let startText = span.split(separator: "-").first,
              let start = Int64(startText)
        else { return nil }
        return start
    }

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
                operation: String(localized: "下載區間", bundle: .module), path: path, underlying: error.localizedDescription
            )
        }
    }

    /// URLComponents rejects a bare IPv6 literal; it has to be bracketed.
    private static func urlHost(for host: String) -> String {
        guard host.contains(":"), !host.hasPrefix("[") else { return host }
        return "[\(host)]"
    }

    private static func validate(
        _ response: URLResponse,
        body: Data? = nil,
        method: Method,
        operation: String,
        path: String
    ) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteFileServiceError.operationFailed(
                operation: operation, path: path, underlying: "非 HTTP 回應"
            )
        }

        // 207 carries per-member results. PROPFIND's body is parsed, so its
        // failures surface there; for anything else the operation may have
        // partially failed and reporting success would lose data.
        if httpResponse.statusCode == Status.multiStatus, method != .propfind {
            let failures = body.map(PropfindResponseParser.failureStatuses) ?? []
            log.error("\(operation) at \(path) returned 207; treating partial result as failure")
            if failures.contains(where: { $0 == Status.unauthorized || $0 == Status.forbidden }) {
                throw RemoteFileServiceError.permissionDenied(operation: operation, path: path)
            }
            let detail = failures.isEmpty ? "" : "：" + failures.map { "HTTP \($0)" }.joined(separator: "、")
            throw RemoteFileServiceError.operationFailed(
                operation: operation, path: path, underlying: "伺服器回報部分項目未完成（207）\(detail)"
            )
        }

        switch httpResponse.statusCode {
        case Status.successRange:
            return
        case Status.unauthorized:
            log.error("\(operation) at \(path) rejected: HTTP 401")
            throw RemoteFileServiceError.authenticationFailed
        case Status.forbidden:
            // Authenticated but not permitted here — a per-item condition, not
            // a reason to put the whole domain into a re-authentication state.
            log.error("\(operation) at \(path) forbidden: HTTP 403")
            throw RemoteFileServiceError.permissionDenied(operation: operation, path: path)
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
        if let urlError, HTTPTransfer.isTransportFailure(urlError.code) {
            log.error("\(operation) at \(path) unreachable: \(String(describing: error))")
            return HTTPTransfer.connectionFailure(urlError)
        }
        switch urlError?.code {
        case .cancelled:
            // The caller's task was cancelled; that is not a server failure.
            return CancellationError()
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
