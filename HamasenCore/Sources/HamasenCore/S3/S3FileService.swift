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

import Crypto
import Foundation

/// S3-compatible implementation of RemoteFileService, built on URLSession.
///
/// One implementation serves R2, Amazon, MinIO, Backblaze and Wasabi: they
/// speak the same REST API and the same signature, and differ only in the
/// endpoint, the region name and where the bucket goes in the URL — all of
/// which `S3Endpoint` holds.
///
/// Object storage is not a file system, and three of the differences reach
/// this far up:
///
/// - There are no directories. A folder is a shared prefix, and an empty one
///   exists only as a zero-byte object whose name ends in a separator.
/// - Nothing is renamed. A move is a server-side copy followed by a delete.
/// - A key may name both an object and a prefix. Finder has no way to show
///   both, so the object wins; see `listDirectory`.
public actor S3FileService: RemoteFileService {
    private enum Method {
        static let get = "GET"
        static let head = "HEAD"
        static let put = "PUT"
        static let post = "POST"
        static let delete = "DELETE"
    }

    private enum Status {
        static let successRange = 200...299
        static let ok = 200
        static let partialContent = 206
        static let rangeNotSatisfiable = 416
    }

    private enum Listing {
        static let typeParameter = URLQueryItem(name: "list-type", value: "2")
        /// Asked for on every listing so a key containing a character XML
        /// cannot carry still arrives intact. The parser decodes only when
        /// the response says it encoded.
        static let encodingParameter = URLQueryItem(name: "encoding-type", value: "url")
        /// A listing that never reported itself finished would otherwise loop
        /// forever against a server whose continuation token does not advance.
        static let maximumPages = 10_000
    }

    public enum Upload {
        /// Above this, the object is sent in parts. Below it a single PUT is
        /// fewer requests and cannot leave an unfinished upload behind.
        public static let defaultMultipartThresholdBytes = 100 * 1024 * 1024
        public static let defaultPartSizeBytes = 16 * 1024 * 1024
        /// S3's own limit. Part size times this is the largest object that
        /// can be uploaded at all, which is why the setting exposing the part
        /// size has to show the product.
        public static let maximumParts = 10_000
    }

    private enum Batch {
        /// DeleteObjects takes at most this many keys per request.
        static let deleteLimit = 1_000
    }

    private static let log = HamasenLog(category: "s3")

    private let config: ServerConfig
    private let endpoint: S3Endpoint
    private let awsCredentials: AWSCredentials?
    private let connectTimeoutSeconds: Int
    private let multipartThresholdBytes: Int
    private let partSizeBytes: Int

    private var session: URLSession?
    /// Requests handed a session but not finished. The session must not be
    /// invalidated while any exist: creating a task on an invalidated session
    /// raises an uncatchable ObjC exception, and that window is open across
    /// every await.
    private var requestsInFlight = 0
    private var isTearingDown = false

    /// - Parameter endpoint: passed in rather than derived here, because the
    ///   region and addressing style are settings a user can override and
    ///   this type should not have to guess them twice.
    public init(
        config: ServerConfig,
        credentials: ServerCredentials,
        endpoint: S3Endpoint,
        connectTimeoutSeconds: Int = AppSettings.defaultConnectTimeoutSeconds,
        multipartThresholdBytes: Int = Upload.defaultMultipartThresholdBytes,
        partSizeBytes: Int = Upload.defaultPartSizeBytes
    ) {
        self.config = config
        self.endpoint = endpoint
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.multipartThresholdBytes = multipartThresholdBytes
        self.partSizeBytes = partSizeBytes
        if case .password(let secret) = credentials {
            self.awsCredentials = AWSCredentials(
                accessKeyID: config.username, secretAccessKey: secret)
        } else {
            self.awsCredentials = nil
        }
    }

    // MARK: - Connection lifecycle

    /// There is no session to open. This checks that the credentials are
    /// accepted and the bucket is there, so a server that will never work is
    /// reported when it is added rather than when Finder first opens it.
    public func connect() async throws {
        guard session == nil, !isTearingDown else { return }
        guard awsCredentials != nil else {
            throw RemoteFileServiceError.unsupportedCredentials(
                protocolName: config.transferProtocol.displayName)
        }
        let object = try rootObject()
        Self.log.debug("Checking bucket \(object.bucket) at \(endpoint.host)")

        // Probed on a session that is not published yet, so a concurrent
        // connect() cannot see success before the credentials are checked.
        let candidate = makeSession()
        do {
            _ = try await send(
                method: Method.head,
                object: S3ObjectKey(bucket: object.bucket, key: ""),
                operation: Self.checkOperation,
                path: RemotePath.root,
                using: candidate)
        } catch {
            candidate.invalidateAndCancel()
            throw error
        }
        session = candidate
    }

    /// HTTP keeps no session to lose, so this reports only whether the
    /// service has been connected and not torn down.
    public var isConnected: Bool {
        session != nil && !isTearingDown
    }

    public func disconnect() async throws {
        isTearingDown = true
        tearDownSessionIfIdle()
    }

    // MARK: - Reading

    public func listDirectory(at path: String) async throws -> [RemoteItem] {
        let object = try object(for: path)
        let prefix = object.directoryPrefix

        var files: [String: RemoteItem] = [:]
        var directories: [String: RemoteItem] = [:]
        var continuationToken: String?
        var pages = 0

        repeat {
            let listing = try await listPage(
                bucket: object.bucket, prefix: prefix,
                continuationToken: continuationToken, path: path)

            for entry in listing.objects {
                // The zero-byte marker of an empty folder comes back as an
                // object whose name after the prefix is empty. It is the
                // folder itself, not something inside it.
                let name = String(entry.key.dropFirst(prefix.count))
                guard !name.isEmpty else { continue }
                files[name] = RemoteItem(
                    path: RemotePath.join(path, name),
                    name: name,
                    kind: .file,
                    size: entry.size,
                    modificationDate: entry.lastModified)
            }
            for common in listing.commonPrefixes {
                let name = RemotePath.withoutTrailingSeparator(
                    String(common.dropFirst(prefix.count)))
                guard !name.isEmpty else { continue }
                directories[name] = RemoteItem(
                    path: RemotePath.join(path, name),
                    name: name,
                    kind: .directory,
                    size: 0)
            }

            continuationToken = listing.isTruncated ? listing.nextContinuationToken : nil
            pages += 1
        } while continuationToken != nil && pages < Listing.maximumPages

        if continuationToken != nil {
            Self.log.error("Listing \(path) stopped after \(pages) pages; results are incomplete")
            throw RemoteFileServiceError.operationFailed(
                operation: Self.listOperation, path: path,
                underlying: "伺服器的列舉沒有結束")
        }

        // A name can be both an object and a prefix, because S3 keys are
        // opaque strings and "a" says nothing about "a/b". Finder cannot show
        // two items with one name, and the object wins: it keeps every lookup
        // to a single HEAD and keeps this agreeing with `itemInfo`, which has
        // no listing to consult. The subtree under the prefix becomes
        // unreachable, which is why it is logged rather than passed over.
        for name in directories.keys where files[name] != nil {
            Self.log.error(
                "\(RemotePath.join(path, name)) is both an object and a prefix; "
                + "showing the object and hiding what is under the prefix")
            directories.removeValue(forKey: name)
        }

        return (Array(files.values) + Array(directories.values)).sorted { $0.name < $1.name }
    }

    public func itemInfo(at path: String) async throws -> RemoteItem {
        // The mount root is a directory by definition, and there is no
        // object to ask about: it is either the bucket or a prefix inside it.
        if path == RemotePath.root {
            return RemoteItem(path: path, name: RemotePath.root, kind: .directory, size: 0)
        }
        let object = try object(for: path)

        do {
            let response = try await send(
                method: Method.head, object: object,
                operation: Self.infoOperation, path: path)
            return RemoteItem(
                path: path,
                name: RemotePath.name(of: path),
                kind: .file,
                size: Self.contentLength(of: response.http),
                modificationDate: Self.lastModified(from: response.http))
        } catch RemoteFileServiceError.itemNotFound {
            // No object under that key. It may still be a folder, which
            // exists only as the shared start of other keys.
            guard try await prefixExists(object, path: path) else {
                throw RemoteFileServiceError.itemNotFound(path: path)
            }
            return RemoteItem(
                path: path, name: RemotePath.name(of: path), kind: .directory, size: 0)
        }
    }

    public func downloadFile(at path: String, to localURL: URL) async throws {
        let object = try object(for: path)
        try await withSession { session in
            let request = try self.signedRequest(
                method: Method.get, object: object, path: path)
            let (temporary, response) = try await session.download(for: request)
            let http = try Self.httpResponse(response, operation: Self.downloadOperation, path: path)
            guard Status.successRange.contains(http.statusCode) else {
                // A failed download still has a body, and it is the error
                // document; reading it is what turns a 403 into a reason.
                let body = try? Data(contentsOf: temporary)
                try? FileManager.default.removeItem(at: temporary)
                throw S3ErrorResponse.remoteError(
                    status: http.statusCode, body: body,
                    operation: Self.downloadOperation, path: path)
            }
            try? FileManager.default.removeItem(at: localURL)
            try FileManager.default.moveItem(at: temporary, to: localURL)
        }
    }

    public func downloadRange(at path: String, offset: Int64, length: Int) async throws -> Data {
        guard length > 0 else { return Data() }
        let object = try object(for: path)
        let lastByte = offset + Int64(length) - 1
        let response = try await send(
            method: Method.get, object: object,
            headers: ["Range": "bytes=\(offset)-\(lastByte)"],
            operation: Self.downloadOperation, path: path,
            acceptableStatuses: [Status.ok, Status.partialContent, Status.rangeNotSatisfiable])

        switch response.http.statusCode {
        case Status.rangeNotSatisfiable:
            // The range began past the end. Fewer bytes than asked for is the
            // documented answer, and none is how many are there.
            return Data()
        case Status.ok:
            // The server ignored Range and sent the whole object; take the
            // slice the caller asked for rather than handing back everything.
            let start = min(Int(offset), response.data.count)
            let end = min(start + length, response.data.count)
            return response.data.subdata(in: start..<end)
        default:
            return response.data
        }
    }

    // MARK: - Writing

    public func uploadFile(from localURL: URL, to path: String) async throws {
        let object = try object(for: path)
        let size = try Self.fileSize(of: localURL)
        if size <= Int64(multipartThresholdBytes) {
            guard let body = try? Data(contentsOf: localURL) else {
                throw RemoteFileServiceError.localFileUnreadable(url: localURL)
            }
            _ = try await send(
                method: Method.put, object: object, body: body,
                operation: Self.uploadOperation, path: path)
            return
        }
        try await uploadInParts(from: localURL, to: object, size: size, path: path)
    }

    /// An empty object whose key ends in a separator. That marker is the only
    /// thing that makes a folder with nothing in it visible, since a folder is
    /// otherwise just the shared start of other keys.
    public func createDirectory(at path: String) async throws {
        let object = try object(for: path)
        _ = try await send(
            method: Method.put, object: object.folderMarker,
            operation: Self.createOperation, path: path)
    }

    public func deleteFile(at path: String) async throws {
        let object = try object(for: path)
        _ = try await send(
            method: Method.delete, object: object,
            operation: Self.deleteOperation, path: path)
    }

    public func deleteDirectory(at path: String) async throws {
        let object = try object(for: path)
        let keys = try await keysUnder(object, path: path, operation: Self.deleteOperation)
        // The marker is not returned by a prefix listing when the prefix is
        // the marker's own key, so it is removed by name as well.
        try await delete(keys: keys + [object.folderMarkerKey],
                         bucket: object.bucket, path: path)
    }

    /// Copy then delete, because object storage has no rename.
    ///
    /// Everything is copied before anything is deleted. A failure partway
    /// through then leaves the source intact and some duplicates behind,
    /// which is recoverable; deleting as it went would lose whatever had not
    /// been copied yet.
    public func moveItem(from oldPath: String, to newPath: String) async throws {
        let source = try object(for: oldPath)
        let destination = try object(for: newPath)

        if try await objectExists(source, path: oldPath) {
            try await copy(from: source, to: destination, path: oldPath)
            _ = try await send(
                method: Method.delete, object: source,
                operation: Self.moveOperation, path: oldPath)
            return
        }

        let keys = try await keysUnder(source, path: oldPath, operation: Self.moveOperation)
        guard !keys.isEmpty else { throw RemoteFileServiceError.itemNotFound(path: oldPath) }

        let sourcePrefix = source.directoryPrefix
        for key in keys {
            let suffix = String(key.dropFirst(sourcePrefix.count))
            try await copy(
                from: S3ObjectKey(bucket: source.bucket, key: key),
                to: S3ObjectKey(bucket: destination.bucket,
                                key: destination.directoryPrefix + suffix),
                path: oldPath)
        }
        try await delete(keys: keys, bucket: source.bucket, path: oldPath)
    }

    // MARK: - Writing helpers

    private func uploadInParts(
        from localURL: URL, to object: S3ObjectKey, size: Int64, path: String
    ) async throws {
        let parts = Int((size + Int64(partSizeBytes) - 1) / Int64(partSizeBytes))
        guard parts <= Upload.maximumParts else {
            throw RemoteFileServiceError.operationFailed(
                operation: Self.uploadOperation, path: path,
                underlying: "檔案超過分段上傳的上限（每段 \(partSizeBytes / 1024 / 1024) MB × \(Upload.maximumParts) 段）")
        }
        guard let handle = try? FileHandle(forReadingFrom: localURL) else {
            throw RemoteFileServiceError.localFileUnreadable(url: localURL)
        }
        defer { try? handle.close() }

        let uploadID = try await beginUpload(object, path: path)
        do {
            var numbers: [Int] = []
            for number in 1...parts {
                let chunk = try handle.read(upToCount: partSizeBytes) ?? Data()
                guard !chunk.isEmpty else { break }
                _ = try await send(
                    method: Method.put, object: object,
                    queryItems: [
                        URLQueryItem(name: "partNumber", value: String(number)),
                        URLQueryItem(name: "uploadId", value: uploadID),
                    ],
                    body: chunk, operation: Self.uploadOperation, path: path)
                numbers.append(number)
            }
            try await completeUpload(uploadID, parts: numbers, object: object, path: path)
        } catch {
            // An upload left open keeps its parts, and the account is billed
            // for them until somebody notices. Abandoning it is not optional.
            await abortUpload(uploadID, object: object, path: path)
            throw error
        }
    }

    private func beginUpload(_ object: S3ObjectKey, path: String) async throws -> String {
        let response = try await send(
            method: Method.post, object: object,
            queryItems: [URLQueryItem(name: "uploads", value: "")],
            operation: Self.uploadOperation, path: path)
        guard let uploadID = Self.firstValue(ofElement: "uploadid", in: response.data) else {
            throw RemoteFileServiceError.operationFailed(
                operation: Self.uploadOperation, path: path,
                underlying: "伺服器沒有回傳分段上傳的識別碼")
        }
        return uploadID
    }

    private func completeUpload(
        _ uploadID: String, parts: [Int], object: S3ObjectKey, path: String
    ) async throws {
        let body = "<CompleteMultipartUpload>"
            + parts.map { "<Part><PartNumber>\($0)</PartNumber></Part>" }.joined()
            + "</CompleteMultipartUpload>"
        _ = try await send(
            method: Method.post, object: object,
            queryItems: [URLQueryItem(name: "uploadId", value: uploadID)],
            body: Data(body.utf8), operation: Self.uploadOperation, path: path)
    }

    private func abortUpload(_ uploadID: String, object: S3ObjectKey, path: String) async {
        _ = try? await send(
            method: Method.delete, object: object,
            queryItems: [URLQueryItem(name: "uploadId", value: uploadID)],
            operation: Self.uploadOperation, path: path)
    }

    private func copy(from source: S3ObjectKey, to destination: S3ObjectKey,
                      path: String) async throws {
        // The header names the source the way a URL path would, so the same
        // encoder the signature uses produces it.
        let reference = AWSSignatureV4.canonicalURI(for: source.absolutePath)
        _ = try await send(
            method: Method.put, object: destination,
            headers: ["x-amz-copy-source": reference],
            operation: Self.moveOperation, path: path)
    }

    private func objectExists(_ object: S3ObjectKey, path: String) async throws -> Bool {
        do {
            _ = try await send(
                method: Method.head, object: object,
                operation: Self.infoOperation, path: path)
            return true
        } catch RemoteFileServiceError.itemNotFound {
            return false
        }
    }

    /// Every key beginning with this prefix, across as many pages as it takes.
    /// No delimiter, because a recursive delete or move wants the whole
    /// subtree rather than one level of it.
    private func keysUnder(
        _ object: S3ObjectKey, path: String, operation: String
    ) async throws -> [String] {
        var keys: [String] = []
        var continuationToken: String?
        var pages = 0
        repeat {
            var query = [
                Listing.typeParameter,
                Listing.encodingParameter,
                URLQueryItem(name: "prefix", value: object.directoryPrefix),
            ]
            if let continuationToken {
                query.append(URLQueryItem(name: "continuation-token", value: continuationToken))
            }
            let response = try await send(
                method: Method.get, object: S3ObjectKey(bucket: object.bucket, key: ""),
                queryItems: query, operation: operation, path: path)
            guard let listing = try? S3ListResponseParser.parse(response.data) else {
                throw RemoteFileServiceError.operationFailed(
                    operation: operation, path: path, underlying: "無法解讀伺服器的列舉回應")
            }
            keys += listing.objects.map(\.key)
            continuationToken = listing.isTruncated ? listing.nextContinuationToken : nil
            pages += 1
        } while continuationToken != nil && pages < Listing.maximumPages

        if continuationToken != nil {
            throw RemoteFileServiceError.operationFailed(
                operation: operation, path: path, underlying: "伺服器的列舉沒有結束")
        }
        return keys
    }

    private func delete(keys: [String], bucket: String, path: String) async throws {
        for batch in stride(from: 0, to: keys.count, by: Batch.deleteLimit) {
            let slice = keys[batch..<min(batch + Batch.deleteLimit, keys.count)]
            let body = Data(("<Delete>"
                + slice.map { "<Object><Key>\(Self.escaped($0))</Key></Object>" }.joined()
                + "</Delete>").utf8)
            _ = try await send(
                method: Method.post, object: S3ObjectKey(bucket: bucket, key: ""),
                queryItems: [URLQueryItem(name: "delete", value: "")],
                // S3 rejects a DeleteObjects request that does not carry it.
                headers: ["Content-MD5": Self.contentMD5(of: body)],
                body: body, operation: Self.deleteOperation, path: path)
        }
    }

    private static func fileSize(of url: URL) throws -> Int64 {
        guard let size = try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? NSNumber
        else { throw RemoteFileServiceError.localFileUnreadable(url: url) }
        return size.int64Value
    }

    private static func contentMD5(of data: Data) -> String {
        Data(Insecure.MD5.hash(data: data)).base64EncodedString()
    }

    private static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func firstValue(ofElement name: String, in data: Data) -> String? {
        let delegate = SingleElementDelegate(elementName: name)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        guard parser.parse() else { return nil }
        return delegate.value
    }

    // MARK: - Listing helpers

    private func listPage(
        bucket: String, prefix: String, continuationToken: String?, path: String
    ) async throws -> S3ListResponseParser.Listing {
        var query = [
            Listing.typeParameter,
            Listing.encodingParameter,
            URLQueryItem(name: "delimiter", value: RemotePath.separator),
        ]
        if !prefix.isEmpty { query.append(URLQueryItem(name: "prefix", value: prefix)) }
        if let continuationToken {
            query.append(URLQueryItem(name: "continuation-token", value: continuationToken))
        }

        let response = try await send(
            method: Method.get, object: S3ObjectKey(bucket: bucket, key: ""),
            queryItems: query, operation: Self.listOperation, path: path)
        do {
            return try S3ListResponseParser.parse(response.data)
        } catch {
            throw RemoteFileServiceError.operationFailed(
                operation: Self.listOperation, path: path,
                underlying: "無法解讀伺服器的列舉回應")
        }
    }

    /// Whether any key starts with this prefix, which is the only sense in
    /// which a folder can be said to exist.
    private func prefixExists(_ object: S3ObjectKey, path: String) async throws -> Bool {
        let response = try await send(
            method: Method.get, object: S3ObjectKey(bucket: object.bucket, key: ""),
            queryItems: [
                Listing.typeParameter,
                Listing.encodingParameter,
                URLQueryItem(name: "prefix", value: object.directoryPrefix),
                URLQueryItem(name: "max-keys", value: "1"),
            ],
            operation: Self.infoOperation, path: path)
        let listing = try? S3ListResponseParser.parse(response.data)
        return !(listing?.objects.isEmpty ?? true) || !(listing?.commonPrefixes.isEmpty ?? true)
    }

    // MARK: - Paths

    private func rootObject() throws -> S3ObjectKey {
        try object(for: RemotePath.root)
    }

    private func object(for mountRelativePath: String) throws -> S3ObjectKey {
        let absolute = RemotePath.resolve(mountRelativePath, against: config.remotePath)
        do {
            return try S3ObjectKey(absolutePath: absolute)
        } catch {
            throw RemoteFileServiceError.operationFailed(
                operation: Self.checkOperation, path: mountRelativePath,
                underlying: "伺服器設定沒有指定 bucket")
        }
    }

    // MARK: - Requests

    private struct Response {
        let data: Data
        let http: HTTPURLResponse
    }

    private func send(
        method: String,
        object: S3ObjectKey,
        queryItems: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data = Data(),
        operation: String,
        path: String,
        acceptableStatuses: Set<Int>? = nil,
        using explicitSession: URLSession? = nil
    ) async throws -> Response {
        let work: (URLSession) async throws -> Response = { session in
            let request = try self.signedRequest(
                method: method, object: object, queryItems: queryItems,
                headers: headers, body: body, path: path)
            let (data, response) = try await session.data(for: request)
            let http = try Self.httpResponse(response, operation: operation, path: path)
            let accepted = acceptableStatuses?.contains(http.statusCode)
                ?? Status.successRange.contains(http.statusCode)
            guard accepted else {
                throw S3ErrorResponse.remoteError(
                    status: http.statusCode, body: data, operation: operation, path: path)
            }
            return Response(data: data, http: http)
        }
        if let explicitSession { return try await work(explicitSession) }
        return try await withSession(work)
    }

    private func signedRequest(
        method: String,
        object: S3ObjectKey,
        queryItems: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data = Data(),
        path: String
    ) throws -> URLRequest {
        guard let awsCredentials else { throw RemoteFileServiceError.notConnected }
        guard let address = endpoint.address(for: object, queryItems: queryItems) else {
            throw RemoteFileServiceError.operationFailed(
                operation: Self.checkOperation, path: path, underlying: "無效的主機或路徑")
        }

        var signable = headers
        signable["Host"] = address.hostHeader
        let signed = AWSSignatureV4.signedHeaders(
            for: AWSSignatureV4.Request(
                method: method, path: address.signingPath, queryItems: queryItems,
                headers: signable, payloadHash: AWSSignatureV4.payloadHash(of: body)),
            credentials: awsCredentials,
            region: endpoint.region,
            signedAt: Date())

        var request = URLRequest(url: address.url)
        request.httpMethod = method
        // Host is set by the loader from the URL. Setting it again is not
        // permitted, and the signature already covers the value it will send.
        for (name, value) in signed where name.lowercased() != "host" {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if !body.isEmpty { request.httpBody = body }
        return request
    }

    private static func httpResponse(
        _ response: URLResponse, operation: String, path: String
    ) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw RemoteFileServiceError.operationFailed(
                operation: operation, path: path, underlying: "非 HTTP 回應")
        }
        return http
    }

    private static let httpDateFormatters: [DateFormatter] = [
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "EEEE, dd-MMM-yy HH:mm:ss zzz",
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }

    /// Read from the header rather than `expectedContentLength`, which
    /// describes the body being delivered — and a HEAD has none, however
    /// large the object it describes.
    private static func contentLength(of response: HTTPURLResponse) -> Int64 {
        if let text = response.value(forHTTPHeaderField: "Content-Length"),
           let size = Int64(text) {
            return size
        }
        return max(0, response.expectedContentLength)
    }

    private static func lastModified(from response: HTTPURLResponse) -> Date? {
        guard let text = response.value(forHTTPHeaderField: "Last-Modified") else { return nil }
        for formatter in httpDateFormatters {
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    // MARK: - Session

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = TimeInterval(connectTimeoutSeconds)
        configuration.httpShouldSetCookies = false
        // A file provider must never serve a cached body: the system asks for
        // contents precisely when it believes the item changed.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
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
        session.finishTasksAndInvalidate()
        self.session = nil
    }

    // MARK: - Operation names, for messages the user sees

    private static let checkOperation = String(localized: "連線", bundle: .module)
    private static let listOperation = String(localized: "列出目錄", bundle: .module)
    private static let infoOperation = String(localized: "讀取項目資訊", bundle: .module)
    private static let downloadOperation = String(localized: "下載", bundle: .module)
    private static let uploadOperation = String(localized: "上傳", bundle: .module)
    private static let createOperation = String(localized: "建立資料夾", bundle: .module)
    private static let deleteOperation = String(localized: "刪除", bundle: .module)
    private static let moveOperation = String(localized: "移動", bundle: .module)
}

/// Reads the first element with a given local name, for the one value a
/// multipart upload needs out of an otherwise uninteresting document.
private final class SingleElementDelegate: NSObject, XMLParserDelegate {
    private let elementName: String
    private(set) var value: String?
    private var text = ""

    init(elementName: String) {
        self.elementName = elementName
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String]
    ) {
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName: String?
    ) {
        if value == nil, elementName.lowercased() == self.elementName {
            value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        text = ""
    }
}
