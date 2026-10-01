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

    /// The multipart threshold and part size an upload should use.
    public typealias UploadSizes = @Sendable () -> (multipartThresholdBytes: Int, partSizeBytes: Int)

    public enum Copy {
        /// CopyObject refuses a source larger than this; the object has to be
        /// copied in ranges instead.
        public static let singleRequestLimitBytes: Int64 = 5 * 1024 * 1024 * 1024
        /// Server-side, so no bytes cross this machine and a part can be far
        /// larger than an upload's. Raised when the object would otherwise
        /// need more than `Upload.maximumParts`.
        public static let defaultPartSizeBytes: Int64 = 512 * 1024 * 1024
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
    /// Read when each upload starts rather than once: the service lives as
    /// long as its connection, and a change in Settings has to reach the
    /// next upload, not the next reconnect.
    private let uploadSizes: UploadSizes
    private let singleCopyLimitBytes: Int64
    private let copyPartSizeBytes: Int64

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
        partSizeBytes: Int = Upload.defaultPartSizeBytes,
        singleCopyLimitBytes: Int64 = Copy.singleRequestLimitBytes,
        copyPartSizeBytes: Int64 = Copy.defaultPartSizeBytes,
        uploadSizes: UploadSizes? = nil
    ) {
        self.config = config
        self.endpoint = endpoint
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.uploadSizes = uploadSizes ?? { (multipartThresholdBytes, partSizeBytes) }
        self.singleCopyLimitBytes = singleCopyLimitBytes
        self.copyPartSizeBytes = copyPartSizeBytes
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
                // Any working key can make this request, so a 403 that names
                // no cause is the key.
                forbiddenMeansCredentials: true,
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
                    modificationDate: entry.lastModified,
                    contentTag: entry.contentTag)
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
                modificationDate: Self.lastModified(from: response.http),
                contentTag: HTTPTransfer.normalizedETag(response.http.value(forHTTPHeaderField: "ETag")))
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

    public func downloadFile(at path: String, to localURL: URL, progress: TransferProgress?) async throws {
        let object = try object(for: path)
        try await withSession { session in
            let request = try self.signedRequest(
                method: Method.get, object: object, path: path)
            let temporary: URL
            let http: HTTPURLResponse
            do {
                let (url, response) = try await session.download(
                    for: request, delegate: Self.progressDelegate(progress))
                temporary = url
                http = try Self.httpResponse(response, operation: Self.downloadOperation, path: path)
            } catch {
                throw Self.mapTransportError(error, operation: Self.downloadOperation, path: path)
            }
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
        // The delegate reports bytes as they arrive, but not reliably the
        // last of them: the call can return before its final callback. The
        // total is known now, so it is reported here whatever came before.
        if let progress, let size = try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            progress(Int64(size))
        }
    }

    public func downloadRange(at path: String, offset: Int64, length: Int) async throws -> Data {
        guard length > 0 else { return Data() }
        let object = try object(for: path)
        let lastByte = offset + Int64(length) - 1

        // Streamed to disk: a server that ignores Range answers with the whole
        // object, which must not be buffered in memory to take a slice of it.
        let (bodyURL, http) = try await withSession { session in
            let request = try self.signedRequest(
                method: Method.get, object: object,
                headers: ["Range": "bytes=\(offset)-\(lastByte)"], path: path)
            do {
                let (url, response) = try await session.download(for: request)
                return (url, try Self.httpResponse(response, operation: Self.downloadOperation, path: path))
            } catch {
                throw Self.mapTransportError(error, operation: Self.downloadOperation, path: path)
            }
        }
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        switch http.statusCode {
        case Status.rangeNotSatisfiable:
            // The range began past the end. Fewer bytes than asked for is the
            // documented answer, and none is how many are there.
            return Data()
        case Status.ok:
            // The server ignored Range and sent the whole object; take the
            // slice the caller asked for rather than handing back everything.
            return try Self.readSlice(from: bodyURL, offset: offset, length: length, path: path)
        case Status.partialContent:
            return try Self.readSlice(from: bodyURL, offset: 0, length: length, path: path)
        default:
            throw S3ErrorResponse.remoteError(
                status: http.statusCode, body: try? Data(contentsOf: bodyURL),
                operation: Self.downloadOperation, path: path)
        }
    }

    // MARK: - Writing

    public func uploadFile(from localURL: URL, to path: String, progress: TransferProgress?) async throws {
        let object = try object(for: path)
        let size = try Self.fileSize(of: localURL)
        let sizes = uploadSizes()
        if size <= Int64(sizes.multipartThresholdBytes) {
            // The file goes out from disk, not from memory. Its hash is taken
            // in a first pass over it so the signature can still cover the
            // body, which every S3-compatible service accepts.
            let payloadHash: String
            do {
                payloadHash = try await AWSSignatureV4.payloadHash(ofFileAt: localURL)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw RemoteFileServiceError.localFileUnreadable(url: localURL)
            }
            _ = try await send(
                method: Method.put, object: object,
                upload: FileUpload(url: localURL, payloadHash: payloadHash), progress: progress,
                operation: Self.uploadOperation, path: path)
        } else {
            try await uploadInParts(
                from: localURL, to: object, size: size, partSizeBytes: sizes.partSizeBytes,
                path: path, progress: progress)
        }
        // The delegate reports bytes as they go, but not reliably the last
        // of them: the call can return before its final callback.
        progress?(size)
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
        let keys = try await objectsUnder(object, path: path, operation: Self.deleteOperation)
            .map(\.key)
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
    /// been copied yet. A copy that reports failure — including one that
    /// answers 200 and says so in the body — throws before the delete.
    public func moveItem(from oldPath: String, to newPath: String) async throws {
        let source = try object(for: oldPath)
        let destination = try object(for: newPath)

        // A copy overwrites silently, unlike the rename every other protocol
        // here performs. The name is taken if either an object or a folder
        // holds it, since listing shows only one of the two.
        let destinationTaken: Bool
        if try await objectSize(destination, path: newPath) != nil {
            destinationTaken = true
        } else {
            destinationTaken = try await prefixExists(destination, path: newPath)
        }
        if destinationTaken {
            throw RemoteFileServiceError.alreadyExists(path: newPath)
        }

        if let state = try await objectState(source, path: oldPath) {
            // Without an ETag nothing can pin the copy and the delete to one
            // version, and a same-size write in between would be lost.
            guard let tag = state.tag else { throw Self.unversioned(path: oldPath) }
            try await copy(from: source, to: destination, size: state.size, tag: tag, path: oldPath)
            do {
                // Only the version that was copied may go: a write to the
                // source after the copy fails this with 412.
                _ = try await send(
                    method: Method.delete, object: source, headers: ["If-Match": "\"\(tag)\""],
                    operation: Self.moveOperation, path: oldPath)
            } catch {
                _ = try? await send(
                    method: Method.delete, object: destination, operation: Self.moveOperation, path: newPath)
                throw error
            }
            return
        }

        let objects = try await objectsUnder(source, path: oldPath, operation: Self.moveOperation)
        guard !objects.isEmpty else { throw RemoteFileServiceError.itemNotFound(path: oldPath) }
        guard objects.allSatisfy({ $0.contentTag != nil }) else { throw Self.unversioned(path: oldPath) }

        let sourcePrefix = source.directoryPrefix
        for entry in objects {
            let suffix = String(entry.key.dropFirst(sourcePrefix.count))
            try await copy(
                from: S3ObjectKey(bucket: source.bucket, key: entry.key),
                to: S3ObjectKey(bucket: destination.bucket,
                                key: destination.directoryPrefix + suffix),
                size: entry.size, tag: entry.contentTag, path: oldPath)
        }
        // Anything written under the source after it was listed — a changed
        // object, a new one — would be lost with it.
        let current = try await objectsUnder(source, path: oldPath, operation: Self.moveOperation)
        guard Self.versions(of: current) == Self.versions(of: objects) else {
            let copiedKeys = objects.map { destination.directoryPrefix + String($0.key.dropFirst(sourcePrefix.count)) }
            try? await delete(keys: copiedKeys, bucket: destination.bucket, path: newPath)
            throw Self.sourceChanged(path: oldPath)
        }
        // Each key goes only if it still has the ETag that was copied.
        try await delete(
            keys: objects.map(\.key), tags: objects.map(\.contentTag), bucket: source.bucket, path: oldPath)
    }

    // MARK: - Writing helpers

    private func uploadInParts(
        from localURL: URL, to object: S3ObjectKey, size: Int64, partSizeBytes: Int, path: String,
        progress: TransferProgress?
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
            var uploaded: [UploadedPart] = []
            for number in 1...parts {
                let chunk = try handle.read(upToCount: partSizeBytes) ?? Data()
                guard !chunk.isEmpty else { break }
                let sentBefore = Int64(number - 1) * Int64(partSizeBytes)
                let response = try await send(
                    method: Method.put, object: object,
                    queryItems: [
                        URLQueryItem(name: "partNumber", value: String(number)),
                        URLQueryItem(name: "uploadId", value: uploadID),
                    ],
                    body: chunk, progress: progress.map { report in { @Sendable bytes in report(sentBefore + bytes) } },
                    operation: Self.uploadOperation, path: path)
                // CompleteMultipartUpload must name every part by the ETag
                // this response gave it; without them S3 refuses to assemble.
                guard let tag = response.http.value(forHTTPHeaderField: "ETag"), !tag.isEmpty else {
                    throw RemoteFileServiceError.operationFailed(
                        operation: Self.uploadOperation, path: path,
                        underlying: "伺服器沒有回傳分段的 ETag")
                }
                uploaded.append(UploadedPart(number: number, tag: tag))
            }
            try await completeUpload(uploadID, parts: uploaded, object: object,
                                     operation: Self.uploadOperation, path: path)
        } catch {
            await abandonUpload(uploadID, object: object, path: path)
            throw error
        }
    }

    private struct UploadedPart {
        let number: Int
        let tag: String
    }

    private func beginUpload(_ object: S3ObjectKey, path: String,
                             operation: String? = nil) async throws -> String {
        let operation = operation ?? Self.uploadOperation
        let response = try await send(
            method: Method.post, object: object,
            queryItems: [URLQueryItem(name: "uploads", value: "")],
            operation: operation, path: path)
        guard let uploadID = Self.firstValue(ofElement: "uploadid", in: response.data) else {
            throw RemoteFileServiceError.operationFailed(
                operation: operation, path: path,
                underlying: "伺服器沒有回傳分段上傳的識別碼")
        }
        return uploadID
    }

    private func completeUpload(
        _ uploadID: String, parts: [UploadedPart], object: S3ObjectKey,
        operation: String, path: String
    ) async throws {
        let body = "<CompleteMultipartUpload>"
            + parts.map {
                "<Part><PartNumber>\($0.number)</PartNumber><ETag>\(Self.escaped($0.tag))</ETag></Part>"
            }.joined()
            + "</CompleteMultipartUpload>"
        _ = try await send(
            method: Method.post, object: object,
            queryItems: [URLQueryItem(name: "uploadId", value: uploadID)],
            body: Data(body.utf8), operation: operation, path: path,
            // Assembling a large object can outlast the response headers, so
            // the service sends 200 first and reports a failure in the body.
            failsOnEmbeddedError: true)
    }

    /// Runs in its own task because the usual reason to abandon an upload is
    /// that this one was cancelled, and a cancelled task cannot send the
    /// request that stops the parts from being billed.
    private func abandonUpload(_ uploadID: String, object: S3ObjectKey, path: String) async {
        await Task {
            _ = try? await self.send(
                method: Method.delete, object: object,
                queryItems: [URLQueryItem(name: "uploadId", value: uploadID)],
                operation: Self.uploadOperation, path: path)
        }.value
    }

    private func copy(from source: S3ObjectKey, to destination: S3ObjectKey,
                      size: Int64, tag: String?, path: String) async throws {
        // The header names the source the way a URL path would, so the same
        // encoder the signature uses produces it.
        let reference = AWSSignatureV4.canonicalURI(for: source.absolutePath)
        // Pinned to the version that was looked at, so a write in between
        // fails the copy instead of copying something else — and every part
        // of a multipart copy comes from the same version.
        var sourceHeaders = ["x-amz-copy-source": reference]
        if let tag { sourceHeaders["x-amz-copy-source-if-match"] = "\"\(tag)\"" }
        guard size > singleCopyLimitBytes else {
            _ = try await send(
                method: Method.put, object: destination,
                headers: sourceHeaders,
                operation: Self.moveOperation, path: path,
                // Large copies are answered 200 before they finish, and a
                // failure after that arrives as an <Error> document.
                failsOnEmbeddedError: true)
            return
        }
        try await copyInParts(sourceHeaders: sourceHeaders, to: destination, size: size, path: path)
    }

    /// What identifies one version of an object: its size and, when the
    /// server gives one, its ETag.
    private struct ObjectState: Equatable {
        let size: Int64
        let tag: String?
    }

    private func objectState(_ object: S3ObjectKey, path: String) async throws -> ObjectState? {
        do {
            let response = try await send(
                method: Method.head, object: object,
                operation: Self.infoOperation, path: path)
            return ObjectState(
                size: Self.contentLength(of: response.http),
                tag: HTTPTransfer.normalizedETag(response.http.value(forHTTPHeaderField: "ETag")))
        } catch RemoteFileServiceError.itemNotFound {
            return nil
        }
    }

    private static func versions(of objects: [S3ListResponseParser.Object]) -> [String: ObjectState] {
        Dictionary(
            objects.map { ($0.key, ObjectState(size: $0.size, tag: $0.contentTag)) },
            uniquingKeysWith: { first, _ in first })
    }

    private static func unversioned(path: String) -> Error {
        RemoteFileServiceError.operationFailed(
            operation: moveOperation, path: path, underlying: "伺服器沒有提供 ETag，無法安全移動")
    }

    private static func sourceChanged(path: String) -> Error {
        RemoteFileServiceError.operationFailed(
            operation: moveOperation, path: path, underlying: "來源在移動期間被修改")
    }

    /// UploadPartCopy, for a source too large for a single CopyObject.
    private func copyInParts(
        sourceHeaders: [String: String], to destination: S3ObjectKey, size: Int64, path: String
    ) async throws {
        let partSize = max(
            copyPartSizeBytes, (size + Int64(Upload.maximumParts) - 1) / Int64(Upload.maximumParts))
        let uploadID = try await beginUpload(destination, path: path, operation: Self.moveOperation)
        do {
            var copied: [UploadedPart] = []
            var start: Int64 = 0
            while start < size {
                let end = min(start + partSize, size) - 1
                let number = copied.count + 1
                let response = try await send(
                    method: Method.put, object: destination,
                    queryItems: [
                        URLQueryItem(name: "partNumber", value: String(number)),
                        URLQueryItem(name: "uploadId", value: uploadID),
                    ],
                    headers: sourceHeaders.merging(
                        ["x-amz-copy-source-range": "bytes=\(start)-\(end)"], uniquingKeysWith: { $1 }),
                    operation: Self.moveOperation, path: path,
                    failsOnEmbeddedError: true)
                guard let tag = Self.firstValue(ofElement: "etag", in: response.data) else {
                    throw RemoteFileServiceError.operationFailed(
                        operation: Self.moveOperation, path: path,
                        underlying: "伺服器沒有回傳分段的 ETag")
                }
                copied.append(UploadedPart(number: number, tag: tag))
                start = end + 1
            }
            try await completeUpload(uploadID, parts: copied, object: destination,
                                     operation: Self.moveOperation, path: path)
        } catch {
            await abandonUpload(uploadID, object: destination, path: path)
            throw error
        }
    }

    /// The object's size, or nil when there is no object under that key.
    private func objectSize(_ object: S3ObjectKey, path: String) async throws -> Int64? {
        do {
            let response = try await send(
                method: Method.head, object: object,
                operation: Self.infoOperation, path: path)
            return Self.contentLength(of: response.http)
        } catch RemoteFileServiceError.itemNotFound {
            return nil
        }
    }

    /// Every key beginning with this prefix, across as many pages as it takes.
    /// No delimiter, because a recursive delete or move wants the whole
    /// subtree rather than one level of it.
    private func objectsUnder(
        _ object: S3ObjectKey, path: String, operation: String
    ) async throws -> [S3ListResponseParser.Object] {
        var objects: [S3ListResponseParser.Object] = []
        try await forEachObject(under: object, path: path, operation: operation) { entry in
            objects.append(entry)
            return .continue
        }
        return objects
    }

    private enum PageWalk {
        case `continue`
        case stop
    }

    /// Pages through a whole subtree, handing each object to `body` and
    /// stopping as soon as it asks to. Shared so a search that has found
    /// enough does not have to read the rest of the bucket to find out.
    private func forEachObject(
        under object: S3ObjectKey,
        path: String,
        operation: String,
        body: (S3ListResponseParser.Object) -> PageWalk
    ) async throws {
        var continuationToken: String?
        var pages = 0
        repeat {
            try Task.checkCancellation()
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
            for entry in listing.objects where body(entry) == .stop {
                return
            }
            continuationToken = listing.isTruncated ? listing.nextContinuationToken : nil
            pages += 1
        } while continuationToken != nil && pages < Listing.maximumPages

        if continuationToken != nil {
            throw RemoteFileServiceError.operationFailed(
                operation: operation, path: path, underlying: "伺服器的列舉沒有結束")
        }
    }

    /// Replaces the walking default, because a bucket can be searched for real.
    ///
    /// `ListObjectsV2` without a delimiter returns every key beneath a prefix,
    /// so one paginated listing covers the whole subtree — where SFTP and the
    /// rest have to visit each directory and give up at a budget. Results here
    /// are complete rather than however far a walk got.
    public func searchItems(
        matching query: String, under path: String, limit: Int
    ) async throws -> [RemoteItem] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, limit > 0 else { return [] }

        let object = try object(for: path)
        let prefix = object.directoryPrefix
        var found: [RemoteItem] = []
        var directoriesSeen: Set<String> = []

        try await forEachObject(under: object, path: path, operation: Self.searchOperation) { entry in
            let suffix = String(entry.key.dropFirst(prefix.count))
            guard !suffix.isEmpty else { return .continue }

            // Folders exist only as the shared start of keys, or as an empty
            // folder's marker, so they are found in the keys' components —
            // each once, however many keys pass through it.
            let components = suffix.split(separator: Character(RemotePath.separator)).map(String.init)
            let isMarker = suffix.hasSuffix(RemotePath.separator)
            let folderCount = isMarker ? components.count : components.count - 1
            for depth in 0..<max(folderCount, 0) {
                let folder = components[0...depth].joined(separator: RemotePath.separator)
                guard directoriesSeen.insert(folder).inserted,
                      components[depth].localizedStandardContains(query) else { continue }
                found.append(RemoteItem(
                    path: RemotePath.join(path, folder), name: components[depth], kind: .directory, size: 0))
                if found.count >= limit { return .stop }
            }

            guard !isMarker else { return .continue }
            let name = RemotePath.name(of: RemotePath.root + suffix)
            guard name.localizedStandardContains(query) else { return .continue }
            found.append(RemoteItem(
                path: RemotePath.join(path, suffix),
                name: name,
                kind: .file,
                size: entry.size,
                modificationDate: entry.lastModified,
                contentTag: entry.contentTag))
            return found.count >= limit ? .stop : .continue
        }
        return found
    }

    /// - Parameter tags: when given, one per key: that key is deleted only
    ///   if it still has this ETag, so a write since it was read survives.
    private func delete(keys: [String], tags: [String?]? = nil, bucket: String, path: String) async throws {
        for batch in stride(from: 0, to: keys.count, by: Batch.deleteLimit) {
            let range = batch..<min(batch + Batch.deleteLimit, keys.count)
            let body = Data(("<Delete>"
                + range.map { index in
                    let tag = tags?[index].map { "<ETag>\(Self.escaped("\"\($0)\""))</ETag>" } ?? ""
                    return "<Object><Key>\(Self.escaped(keys[index]))</Key>\(tag)</Object>"
                }.joined()
                + "</Delete>").utf8)
            let response = try await send(
                method: Method.post, object: S3ObjectKey(bucket: bucket, key: ""),
                queryItems: [URLQueryItem(name: "delete", value: "")],
                // S3 rejects a DeleteObjects request that does not carry it.
                headers: ["Content-MD5": Self.contentMD5(of: body)],
                body: body, operation: Self.deleteOperation, path: path)
            // The request as a whole succeeds with 200 even when individual
            // keys were refused, and reporting that as a delete would let a
            // move drop a source it never finished copying. A key that was
            // already gone is the outcome that was asked for.
            let refused = S3ErrorResponse.embeddedErrors(in: response.data)
                .first { $0.code != "NoSuchKey" }
            if let refused {
                throw S3ErrorResponse.remoteError(
                    status: Status.ok, parsed: refused,
                    operation: Self.deleteOperation, path: path)
            }
        }
    }

    private static func fileSize(of url: URL) throws -> Int64 {
        guard let size = try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? NSNumber
        else { throw RemoteFileServiceError.localFileUnreadable(url: url) }
        return size.int64Value
    }

    /// Reads a byte range back out of a downloaded body file.
    private static func readSlice(from url: URL, offset: Int64, length: Int, path: String) throws -> Data {
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            try file.seek(toOffset: UInt64(max(offset, 0)))
            return try file.read(upToCount: length) ?? Data()
        } catch {
            throw RemoteFileServiceError.operationFailed(
                operation: downloadOperation, path: path, underlying: error.localizedDescription)
        }
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
        // An answer that cannot be read is not "nothing there": a move takes
        // that to mean the name is free and copies over whatever holds it.
        guard let listing = try? S3ListResponseParser.parse(response.data) else {
            throw RemoteFileServiceError.operationFailed(
                operation: Self.infoOperation, path: path, underlying: "無法解讀伺服器的列舉回應")
        }
        return !listing.objects.isEmpty || !listing.commonPrefixes.isEmpty
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

    /// A local file sent as the request body, straight from disk.
    private struct FileUpload {
        let url: URL
        let payloadHash: String
    }

    /// - Parameters:
    ///   - upload: the body, when it is a file too large to hold in memory.
    ///   - progress: receives the bytes of the body sent so far.
    ///   - failsOnEmbeddedError: for the calls that can answer 200 and report
    ///     the failure in the body.
    ///   - forbiddenMeansCredentials: see `S3ErrorResponse.remoteError`.
    private func send(
        method: String,
        object: S3ObjectKey,
        queryItems: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data = Data(),
        upload: FileUpload? = nil,
        progress: TransferProgress? = nil,
        operation: String,
        path: String,
        acceptableStatuses: Set<Int>? = nil,
        failsOnEmbeddedError: Bool = false,
        forbiddenMeansCredentials: Bool = false,
        using explicitSession: URLSession? = nil
    ) async throws -> Response {
        let work: (URLSession) async throws -> Response = { session in
            var request = try self.signedRequest(
                method: method, object: object, queryItems: queryItems,
                headers: headers, body: body, payloadHash: upload?.payloadHash, path: path)
            let data: Data
            let response: URLResponse
            do {
                if let upload {
                    (data, response) = try await session.upload(
                        for: request, fromFile: upload.url,
                        delegate: Self.progressDelegate(progress))
                } else if let progress, !body.isEmpty {
                    (data, response) = try await session.upload(
                        for: request, from: body, delegate: Self.progressDelegate(progress))
                } else {
                    if !body.isEmpty { request.httpBody = body }
                    (data, response) = try await session.data(for: request)
                }
            } catch {
                throw Self.mapTransportError(error, operation: operation, path: path)
            }
            let http = try Self.httpResponse(response, operation: operation, path: path)
            let accepted = acceptableStatuses?.contains(http.statusCode)
                ?? Status.successRange.contains(http.statusCode)
            guard accepted else {
                throw S3ErrorResponse.remoteError(
                    status: http.statusCode, body: data, operation: operation, path: path,
                    forbiddenMeansCredentials: forbiddenMeansCredentials)
            }
            if failsOnEmbeddedError, let failure = S3ErrorResponse.embeddedErrors(in: data).first {
                throw S3ErrorResponse.remoteError(
                    status: http.statusCode, parsed: failure, operation: operation, path: path)
            }
            return Response(data: data, http: http)
        }
        if let explicitSession { return try await work(explicitSession) }
        return try await withSession(work)
    }

    /// Returns the request without its body: how the body travels depends on
    /// whether it is uploaded from a file, from memory, or sent inline.
    private func signedRequest(
        method: String,
        object: S3ObjectKey,
        queryItems: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data = Data(),
        payloadHash: String? = nil,
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
                headers: signable,
                payloadHash: payloadHash ?? AWSSignatureV4.payloadHash(of: body)),
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
        return request
    }

    private static func progressDelegate(_ progress: TransferProgress?) -> TransferProgressDelegate? {
        progress.map { TransferProgressDelegate(progress: $0) }
    }

    /// Transport failures are the server being unreachable, which is not the
    /// same thing to the user as the server refusing the request.
    private static func mapTransportError(_ error: Error, operation: String, path: String) -> Error {
        guard let urlError = error as? URLError else { return error }
        if HTTPTransfer.isTransportFailure(urlError.code) {
            log.error("\(operation) at \(path) unreachable: \(String(describing: error))")
            return RemoteFileServiceError.connectionFailed(underlying: urlError.localizedDescription)
        }
        if urlError.code == .cancelled { return CancellationError() }
        log.error("\(operation) at \(path) failed: \(String(describing: error))")
        return RemoteFileServiceError.operationFailed(
            operation: operation, path: path, underlying: urlError.localizedDescription)
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
        self.session = nil
        // Cleared with the session, or connect() would refuse to make a new
        // one and the service could never be used again.
        isTearingDown = false
        session.finishTasksAndInvalidate()
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
    private static let searchOperation = String(localized: "搜尋", bundle: .module)
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
