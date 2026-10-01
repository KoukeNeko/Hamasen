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
import NIOCore
import NIOHTTP1
import NIOPosix
import HamasenCore

/// In-process S3-compatible server, so the S3 tests are as hermetic as the
/// SFTP and FTP ones: no cloud account, no container, no network.
///
/// It verifies every request's SigV4 signature. A fake that waved requests
/// through would leave the hardest part of this feature untested by the very
/// tests that exercise it end to end.
///
/// Only path-style addressing is served. A loopback address cannot host
/// `bucket.127.0.0.1`, so virtual-hosted addressing is unreachable from here
/// and is covered by `S3EndpointTests` instead.
public final class TestS3Server {
    public static let credentials = AWSCredentials(
        accessKeyID: "AKIAIOSFODNN7EXAMPLE",
        secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
    public static let bucket = "hamasen-test"

    /// Behaviour real implementations differ on, which a uniformly
    /// well-behaved fake would hide.
    public struct Behaviour: Sendable {
        /// Caps a listing so pagination is exercised without needing a
        /// thousand objects to trigger it.
        public var maxKeysPerPage = 1_000
        /// Return keys raw despite `encoding-type=url`, as some
        /// implementations do.
        public var ignoresEncodingType = false
        /// Answer writes with AccessDenied while still accepting the
        /// signature, the way a read-only key behaves.
        public var forbidsWrites = false
        /// Serve this many writes, then fail every one after. Lets a test
        /// interrupt a multipart upload partway, which is the only way to
        /// find out whether the parts already sent are abandoned — an upload
        /// left open keeps billing for them.
        public var failWritesAfter: Int?
        /// Refuse a CopyObject whose source is larger than this, as S3 does
        /// above 5 GB. Lets a test reach that limit without 5 GB of data.
        public var maxCopySourceBytes: Int?
        /// Answer CopyObject with 200 and an `<Error>` document, which is how
        /// a copy that fails after the response has started is reported.
        public var copyFailsWithStatusOK = false
        /// Same, for CompleteMultipartUpload.
        public var completeFailsWithStatusOK = false
        /// Answer CopyObject with 200 and an empty body, copying nothing — a
        /// proxy's idea of success.
        public var copyAnswersEmptyOK = false
        /// Keys DeleteObjects reports as `<Error>` entries inside a 200.
        public var deleteRefusedKeys: Set<String> = []
        /// Answer a ranged GET with the whole object and status 200.
        public var ignoresRange = false

        public static let wellBehaved = Behaviour()

        public init(
            maxKeysPerPage: Int = 1_000,
            ignoresEncodingType: Bool = false,
            forbidsWrites: Bool = false,
            failWritesAfter: Int? = nil,
            maxCopySourceBytes: Int? = nil,
            copyFailsWithStatusOK: Bool = false,
            completeFailsWithStatusOK: Bool = false,
            copyAnswersEmptyOK: Bool = false,
            deleteRefusedKeys: Set<String> = [],
            ignoresRange: Bool = false
        ) {
            self.maxKeysPerPage = maxKeysPerPage
            self.ignoresEncodingType = ignoresEncodingType
            self.forbidsWrites = forbidsWrites
            self.failWritesAfter = failWritesAfter
            self.maxCopySourceBytes = maxCopySourceBytes
            self.copyFailsWithStatusOK = copyFailsWithStatusOK
            self.completeFailsWithStatusOK = completeFailsWithStatusOK
            self.copyAnswersEmptyOK = copyAnswersEmptyOK
            self.deleteRefusedKeys = deleteRefusedKeys
            self.ignoresRange = ignoresRange
        }
    }

    private static let portRange = 20_000..<60_000
    private static let maxBindAttempts = 5

    public let port: Int
    public let store: TestS3ObjectStore
    private let channel: Channel
    private let group: MultiThreadedEventLoopGroup

    private init(port: Int, store: TestS3ObjectStore, channel: Channel,
                 group: MultiThreadedEventLoopGroup) {
        self.port = port
        self.store = store
        self.channel = channel
        self.group = group
    }

    public var endpoint: S3Endpoint {
        S3Endpoint(scheme: "http", host: "127.0.0.1", port: port,
                   region: S3Endpoint.regionlessRegion, addressingStyle: .path)
    }

    public static func start(
        behaviour: Behaviour = .wellBehaved,
        preferredPort: Int? = nil
    ) async throws -> TestS3Server {
        let store = TestS3ObjectStore()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(S3Handler(store: store, behaviour: behaviour))
                }
            }

        var lastError: Error?
        for attempt in 0..<maxBindAttempts {
            let candidatePort = attempt == 0 ? (preferredPort ?? Int.random(in: portRange))
                : Int.random(in: portRange)
            do {
                let channel = try await bootstrap.bind(host: "127.0.0.1", port: candidatePort).get()
                return TestS3Server(
                    port: candidatePort, store: store, channel: channel, group: group)
            } catch {
                lastError = error
            }
        }
        try? await group.shutdownGracefully()
        throw lastError ?? RemoteFileServiceError.connectionFailed(underlying: "無法綁定測試埠")
    }

    /// Reads one element out of a response body, for a caller driving the
    /// HTTP API directly rather than through the client.
    public static func value(ofElement name: String, in data: Data) -> String? {
        S3Handler.values(ofElement: name, in: data).first
    }

    public func stop() async throws {
        try? await channel.close()
        try? await group.shutdownGracefully()
    }
}

// MARK: - Storage

/// Objects live in a dictionary rather than a directory because S3 keys are
/// not paths. "notes" and "notes/draft" are both ordinary keys in the same
/// bucket, and no filesystem can hold a file and a directory under one name.
public final class TestS3ObjectStore: @unchecked Sendable {
    public struct StoredObject: Sendable, Equatable {
        public var data: Data
        public var lastModified: Date
    }

    struct StoredPart {
        let data: Data
        let entityTag: String
    }

    /// How a CompleteMultipartUpload can be refused, each with the error
    /// code S3 gives it.
    public enum CompletionFailure: String, Error, Sendable {
        case noSuchUpload = "NoSuchUpload"
        /// A part was left out of the request, or named with the wrong ETag.
        case invalidPart = "InvalidPart"
        case invalidPartOrder = "InvalidPartOrder"
    }

    private let lock = NSLock()
    private var objects: [String: StoredObject] = [:]
    private var uploads: [String: [Int: StoredPart]] = [:]
    private var writes = 0
    private var listings = 0
    private var completedUploads = 0

    /// How many times a bucket listing was served, so a test can tell one
    /// request covering a subtree from one request per directory.
    public var listingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return listings
    }

    public func recordListing() {
        lock.lock()
        defer { lock.unlock() }
        listings += 1
    }

    public func recordWrite() {
        lock.lock()
        defer { lock.unlock() }
        writes += 1
    }

    public var writeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return writes
    }

    public func put(_ data: Data, forKey key: String, modifiedAt date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        objects[key] = StoredObject(data: data, lastModified: date)
    }

    public func object(forKey key: String) -> StoredObject? {
        lock.lock()
        defer { lock.unlock() }
        return objects[key]
    }

    @discardableResult
    public func remove(key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return objects.removeValue(forKey: key) != nil
    }

    /// Sorted, because S3 lists keys in lexicographic order and pagination is
    /// meaningless without a stable one.
    public func sortedKeys() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return objects.keys.sorted()
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return objects.count
    }

    // MARK: Multipart

    public func beginUpload() -> String {
        let id = UUID().uuidString
        lock.lock()
        defer { lock.unlock() }
        uploads[id] = [:]
        return id
    }

    public func addPart(_ data: Data, number: Int, entityTag: String, toUpload id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard uploads[id] != nil else { return false }
        uploads[id]?[number] = StoredPart(data: data, entityTag: entityTag)
        return true
    }

    /// Assembles the parts the way S3 does: every part must be named with the
    /// ETag its upload returned, in ascending order. A client that leaves the
    /// ETags out is refused here exactly as it is by the real service.
    public func completeUpload(
        _ id: String, parts requested: [(number: Int, entityTag: String?)]
    ) -> Result<Data, CompletionFailure> {
        lock.lock()
        defer { lock.unlock() }
        guard let parts = uploads[id] else { return .failure(.noSuchUpload) }
        guard requested.map(\.number) == requested.map(\.number).sorted() else {
            return .failure(.invalidPartOrder)
        }
        var assembled = Data()
        for (number, entityTag) in requested {
            guard let part = parts[number], let entityTag,
                  entityTag.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) == part.entityTag
            else { return .failure(.invalidPart) }
            assembled.append(part.data)
        }
        uploads.removeValue(forKey: id)
        completedUploads += 1
        return .success(assembled)
    }

    public func abortUpload(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return uploads.removeValue(forKey: id) != nil
    }

    public var openUploadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return uploads.count
    }

    /// How many multipart uploads were assembled, so a test can tell which
    /// way a file was sent.
    public var completedMultipartUploadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return completedUploads
    }
}
