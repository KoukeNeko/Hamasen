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
@testable import HamasenCore

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
final class TestS3Server {
    static let credentials = AWSCredentials(
        accessKeyID: "AKIAIOSFODNN7EXAMPLE",
        secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
    static let bucket = "hamasen-test"

    /// Behaviour real implementations differ on, which a uniformly
    /// well-behaved fake would hide.
    struct Behaviour: Sendable {
        /// Caps a listing so pagination is exercised without needing a
        /// thousand objects to trigger it.
        var maxKeysPerPage = 1_000
        /// Return keys raw despite `encoding-type=url`, as some
        /// implementations do.
        var ignoresEncodingType = false
        /// Answer writes with AccessDenied while still accepting the
        /// signature, the way a read-only key behaves.
        var forbidsWrites = false
        /// Serve this many writes, then fail every one after. Lets a test
        /// interrupt a multipart upload partway, which is the only way to
        /// find out whether the parts already sent are abandoned — an upload
        /// left open keeps billing for them.
        var failWritesAfter: Int?

        static let wellBehaved = Behaviour()
    }

    private static let portRange = 20_000..<60_000
    private static let maxBindAttempts = 5

    let port: Int
    let store: TestS3ObjectStore
    private let channel: Channel
    private let group: MultiThreadedEventLoopGroup

    private init(port: Int, store: TestS3ObjectStore, channel: Channel,
                 group: MultiThreadedEventLoopGroup) {
        self.port = port
        self.store = store
        self.channel = channel
        self.group = group
    }

    /// An endpoint pointing at this server, for a service under test.
    var endpoint: S3Endpoint {
        S3Endpoint(scheme: "http", host: "127.0.0.1", port: port,
                   region: S3Endpoint.regionlessRegion, addressingStyle: .path)
    }

    static func start(behaviour: Behaviour = .wellBehaved) async throws -> TestS3Server {
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
        for _ in 0..<maxBindAttempts {
            let candidatePort = Int.random(in: portRange)
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

    func stop() async throws {
        try? await channel.close()
        try? await group.shutdownGracefully()
    }
}

// MARK: - Storage

/// Objects live in a dictionary rather than a directory because S3 keys are
/// not paths. "notes" and "notes/draft" are both ordinary keys in the same
/// bucket, and no filesystem can hold a file and a directory under one name.
final class TestS3ObjectStore: @unchecked Sendable {
    struct StoredObject: Sendable, Equatable {
        var data: Data
        var lastModified: Date
    }

    private let lock = NSLock()
    private var objects: [String: StoredObject] = [:]
    private var uploads: [String: [Int: Data]] = [:]
    private var writes = 0

    func recordWrite() {
        lock.lock()
        defer { lock.unlock() }
        writes += 1
    }

    var writeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return writes
    }

    func put(_ data: Data, forKey key: String, modifiedAt date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        objects[key] = StoredObject(data: data, lastModified: date)
    }

    func object(forKey key: String) -> StoredObject? {
        lock.lock()
        defer { lock.unlock() }
        return objects[key]
    }

    @discardableResult
    func remove(key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return objects.removeValue(forKey: key) != nil
    }

    /// Sorted, because S3 lists keys in lexicographic order and pagination is
    /// meaningless without a stable one.
    func sortedKeys() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return objects.keys.sorted()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return objects.count
    }

    // MARK: Multipart

    func beginUpload() -> String {
        let id = UUID().uuidString
        lock.lock()
        defer { lock.unlock() }
        uploads[id] = [:]
        return id
    }

    func addPart(_ data: Data, number: Int, toUpload id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard uploads[id] != nil else { return false }
        uploads[id]?[number] = data
        return true
    }

    /// Assembles the parts in the order the client listed them, which is what
    /// makes a wrongly ordered CompleteMultipartUpload produce a wrong file
    /// here as it would anywhere else.
    func completeUpload(_ id: String, partNumbers: [Int]) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let parts = uploads[id] else { return nil }
        var assembled = Data()
        for number in partNumbers {
            guard let part = parts[number] else { return nil }
            assembled.append(part)
        }
        uploads.removeValue(forKey: id)
        return assembled
    }

    func abortUpload(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return uploads.removeValue(forKey: id) != nil
    }

    var openUploadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return uploads.count
    }
}
