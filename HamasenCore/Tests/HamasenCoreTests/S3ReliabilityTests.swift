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
import Testing
@testable import HamasenCore
import HamasenTestServers

/// Failure handling, memory behaviour and progress of the S3 client, against
/// the in-process server that verifies signatures and multipart rules.
@Suite("S3 reliability")
struct S3ReliabilityTests {
    private func withService(
        behaviour: TestS3Server.Behaviour = .wellBehaved,
        multipartThresholdBytes: Int = S3FileService.Upload.defaultMultipartThresholdBytes,
        partSizeBytes: Int = S3FileService.Upload.defaultPartSizeBytes,
        singleCopyLimitBytes: Int64 = S3FileService.Copy.singleRequestLimitBytes,
        copyPartSizeBytes: Int64 = S3FileService.Copy.defaultPartSizeBytes,
        _ work: (S3FileService, TestS3Server) async throws -> Void
    ) async throws {
        let server = try await TestS3Server.start(behaviour: behaviour)
        let service = S3FileService(
            config: ServerConfig(
                name: "測試 S3", transferProtocol: .s3, host: "127.0.0.1", port: 443,
                username: TestS3Server.credentials.accessKeyID,
                remotePath: "/\(TestS3Server.bucket)"),
            credentials: .password(TestS3Server.credentials.secretAccessKey),
            endpoint: server.endpoint,
            multipartThresholdBytes: multipartThresholdBytes,
            partSizeBytes: partSizeBytes,
            singleCopyLimitBytes: singleCopyLimitBytes,
            copyPartSizeBytes: copyPartSizeBytes)
        do {
            try await service.connect()
            try await work(service, server)
        } catch {
            try? await service.disconnect()
            try? await server.stop()
            throw error
        }
        try await service.disconnect()
        try await server.stop()
    }

    private func temporaryFile(_ contents: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("s3-reliability-\(UUID().uuidString)")
        try contents.write(to: url)
        return url
    }

    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var totals: [Int64] = []

        func record(_ total: Int64) {
            lock.lock()
            defer { lock.unlock() }
            totals.append(total)
        }

        var reported: [Int64] {
            lock.lock()
            defer { lock.unlock() }
            return totals
        }
    }

    // MARK: - Multipart upload

    @Test
    func multipartUploadNamesEveryPartByItsETag() async throws {
        // The server refuses to assemble parts that arrive without their
        // ETags, as AWS does, so a completed upload proves they were sent.
        try await withService(multipartThresholdBytes: 100, partSizeBytes: 40) { service, server in
            let payload = Data((0..<250).map { UInt8($0 % 251) })
            let source = try temporaryFile(payload)
            defer { try? FileManager.default.removeItem(at: source) }

            let progress = ProgressLog()
            try await service.uploadFile(from: source, to: "/big.bin", progress: { progress.record($0) })

            #expect(server.store.object(forKey: "big.bin")?.data == payload)
            #expect(server.store.openUploadCount == 0)
            #expect(progress.reported.last == Int64(payload.count))
            #expect(progress.reported == progress.reported.sorted())
        }
    }

    @Test
    func aCompletionThatFailsInsideA200IsAnErrorAndAbandonsTheUpload() async throws {
        try await withService(
            behaviour: .init(completeFailsWithStatusOK: true),
            multipartThresholdBytes: 100, partSizeBytes: 40
        ) { service, server in
            let source = try temporaryFile(Data(repeating: 1, count: 150))
            defer { try? FileManager.default.removeItem(at: source) }
            await #expect(throws: RemoteFileServiceError.self) {
                try await service.uploadFile(from: source, to: "/big.bin")
            }
            #expect(server.store.object(forKey: "big.bin") == nil)
            #expect(server.store.openUploadCount == 0)
        }
    }

    // MARK: - Settings

    /// The service outlives a change in Settings, since the extension keeps
    /// it for as long as the connection lasts; the next upload has to use
    /// the new sizes, not the ones the service was made with.
    @Test
    func uploadSizesAreReadWhenEachUploadStarts() async throws {
        let server = try await TestS3Server.start()
        let sizes = UploadSizesBox(threshold: 1_000, partSize: 1_000)
        let service = S3FileService(
            config: ServerConfig(
                name: "測試 S3", transferProtocol: .s3, host: "127.0.0.1", port: 443,
                username: TestS3Server.credentials.accessKeyID,
                remotePath: "/\(TestS3Server.bucket)"),
            credentials: .password(TestS3Server.credentials.secretAccessKey),
            endpoint: server.endpoint,
            uploadSizes: { sizes.current })
        let payload = Data(repeating: 7, count: 250)
        let source = try temporaryFile(payload)
        defer { try? FileManager.default.removeItem(at: source) }

        do {
            try await service.connect()
            try await service.uploadFile(from: source, to: "/single.bin")
            #expect(server.store.completedMultipartUploadCount == 0)

            sizes.set(threshold: 100, partSize: 100)
            try await service.uploadFile(from: source, to: "/parts.bin")
            #expect(server.store.completedMultipartUploadCount == 1)
            #expect(server.store.object(forKey: "parts.bin")?.data == payload)
        } catch {
            try? await service.disconnect()
            try? await server.stop()
            throw error
        }
        try await service.disconnect()
        try await server.stop()
    }

    // MARK: - Search

    /// A folder exists on S3 only as the start of its keys, so a search by a
    /// folder's name has to find it there.
    @Test
    func searchFindsFoldersByName() async throws {
        try await withService { service, server in
            server.store.put(Data("1".utf8), forKey: "assets/icons/a.png")
            server.store.put(Data("2".utf8), forKey: "assets/b.png")
            server.store.put(Data(), forKey: "empty-assets/")
            let found = try await service.searchItems(matching: "assets", under: "/", limit: 10)
            #expect(Set(found.filter(\.isDirectory).map(\.path)) == ["/assets", "/empty-assets"])
            #expect(found.filter { $0.path == "/assets" }.count == 1)
        }
    }

    // MARK: - Reconnecting

    @Test("中斷連線後可以重新連線")
    func reconnectsAfterDisconnecting() async throws {
        try await withService { service, server in
            try await service.disconnect()
            #expect(await service.isConnected == false)
            try await service.connect()
            #expect(await service.isConnected == true)
            _ = try await service.listDirectory(at: "/")
            _ = server
        }
    }

    // MARK: - Single PUT from disk

    @Test
    func aSinglePutIsStreamedFromDiskAndSigned() async throws {
        try await withService { service, server in
            let payload = Data((0..<3_000_000).map { UInt8($0 % 251) })
            let source = try temporaryFile(payload)
            defer { try? FileManager.default.removeItem(at: source) }

            let progress = ProgressLog()
            try await service.uploadFile(from: source, to: "/plain.bin", progress: { progress.record($0) })

            // The server checks the declared hash against the bytes received,
            // so this passing means the streamed hash matches the body.
            #expect(server.store.object(forKey: "plain.bin")?.data == payload)
            #expect(progress.reported.last == Int64(payload.count))
        }
    }

    @Test
    func streamedFileHashMatchesTheInMemoryHash() async throws {
        // Larger than the read chunk, and not a multiple of it.
        let payload = Data((0..<(2 * 1024 * 1024 + 123)).map { UInt8($0 % 249) })
        let source = try temporaryFile(payload)
        defer { try? FileManager.default.removeItem(at: source) }
        let streamed = try await AWSSignatureV4.payloadHash(ofFileAt: source)
        #expect(streamed == AWSSignatureV4.payloadHash(of: payload))
    }

    @Test
    func anEmptyFileUploads() async throws {
        try await withService { service, server in
            let source = try temporaryFile(Data())
            defer { try? FileManager.default.removeItem(at: source) }
            try await service.uploadFile(from: source, to: "/empty.txt")
            #expect(server.store.object(forKey: "empty.txt")?.data == Data())
        }
    }

    // MARK: - Download

    @Test
    func downloadReportsProgress() async throws {
        try await withService { service, server in
            let payload = Data((0..<3_000_000).map { UInt8($0 % 251) })
            server.store.put(payload, forKey: "down.bin")
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("s3-down-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: destination) }

            let progress = ProgressLog()
            try await service.downloadFile(at: "/down.bin", to: destination, progress: { progress.record($0) })
            #expect(progress.reported.last == Int64(payload.count))
            #expect(try Data(contentsOf: destination) == payload)
        }
    }

    @Test
    func aRangeIsSlicedWhenTheServerIgnoresIt() async throws {
        try await withService(behaviour: .init(ignoresRange: true)) { service, server in
            server.store.put(Data("0123456789".utf8), forKey: "n.txt")
            let middle = try await service.downloadRange(at: "/n.txt", offset: 2, length: 4)
            let tail = try await service.downloadRange(at: "/n.txt", offset: 8, length: 99)
            let beyond = try await service.downloadRange(at: "/n.txt", offset: 50, length: 4)
            #expect(middle == Data("2345".utf8))
            #expect(tail == Data("89".utf8))
            #expect(beyond.isEmpty)
        }
    }

    // MARK: - Content tag

    @Test
    func listingAndLookupAgreeOnTheContentTag() async throws {
        try await withService { service, server in
            server.store.put(Data("tagged".utf8), forKey: "a.txt")
            let listed = try #require(try await service.listDirectory(at: "/").first)
            let looked = try await service.itemInfo(at: "/a.txt")
            let tag = try #require(listed.contentTag)
            #expect(!tag.contains("\""))
            #expect(looked.contentTag == tag)
            #expect(looked.contentVersionToken == listed.contentVersionToken)
        }
    }

    // MARK: - Errors

    @Test
    func aDeniedWriteIsPermissionDeniedNotAuthentication() async throws {
        try await withService(behaviour: .init(forbidsWrites: true)) { service, _ in
            let source = try temporaryFile(Data("x".utf8))
            defer { try? FileManager.default.removeItem(at: source) }
            do {
                try await service.uploadFile(from: source, to: "/nope.txt")
                Issue.record("expected the write to be refused")
            } catch RemoteFileServiceError.permissionDenied(_, let path) {
                #expect(path == "/nope.txt")
            }
        }
    }

    @Test
    func anUnreachableServerIsConnectionFailed() async throws {
        let server = try await TestS3Server.start()
        let endpoint = server.endpoint
        try await server.stop()

        let service = S3FileService(
            config: ServerConfig(
                name: "測試 S3", transferProtocol: .s3, host: "127.0.0.1", port: 443,
                username: TestS3Server.credentials.accessKeyID,
                remotePath: "/\(TestS3Server.bucket)"),
            credentials: .password(TestS3Server.credentials.secretAccessKey),
            endpoint: endpoint)
        do {
            try await service.connect()
            Issue.record("expected the connection to fail")
        } catch RemoteFileServiceError.connectionFailed {
        }
    }

    // MARK: - Move

    @Test
    func aCopyThatFailsInsideA200LeavesTheSourceInPlace() async throws {
        try await withService(behaviour: .init(copyFailsWithStatusOK: true)) { service, server in
            server.store.put(Data("precious".utf8), forKey: "a.txt")
            await #expect(throws: RemoteFileServiceError.self) {
                try await service.moveItem(from: "/a.txt", to: "/b.txt")
            }
            #expect(server.store.object(forKey: "a.txt")?.data == Data("precious".utf8))
            #expect(server.store.object(forKey: "b.txt") == nil)
        }
    }

    @Test
    func aFolderMoveThatCannotCopyKeepsEverySource() async throws {
        try await withService(behaviour: .init(copyFailsWithStatusOK: true)) { service, server in
            server.store.put(Data("1".utf8), forKey: "dir/1.txt")
            server.store.put(Data("2".utf8), forKey: "dir/2.txt")
            await #expect(throws: RemoteFileServiceError.self) {
                try await service.moveItem(from: "/dir", to: "/moved")
            }
            #expect(server.store.object(forKey: "dir/1.txt") != nil)
            #expect(server.store.object(forKey: "dir/2.txt") != nil)
        }
    }

    @Test
    func aMoveOntoAnExistingObjectFailsAndOverwritesNothing() async throws {
        try await withService { service, server in
            server.store.put(Data("source".utf8), forKey: "a.txt")
            server.store.put(Data("keep me".utf8), forKey: "b.txt")
            await #expect(throws: RemoteFileServiceError.alreadyExists(path: "/b.txt")) {
                try await service.moveItem(from: "/a.txt", to: "/b.txt")
            }
            #expect(server.store.object(forKey: "b.txt")?.data == Data("keep me".utf8))
            #expect(server.store.object(forKey: "a.txt") != nil)
        }
    }

    @Test
    func aMoveOntoAnExistingFolderFails() async throws {
        try await withService { service, server in
            server.store.put(Data("source".utf8), forKey: "a.txt")
            server.store.put(Data("inside".utf8), forKey: "docs/x.txt")
            await #expect(throws: RemoteFileServiceError.alreadyExists(path: "/docs")) {
                try await service.moveItem(from: "/a.txt", to: "/docs")
            }
            await #expect(throws: RemoteFileServiceError.alreadyExists(path: "/docs")) {
                try await service.moveItem(from: "/other", to: "/docs")
            }
        }
    }

    // MARK: - Delete

    @Test
    func aFolderDeleteFailsWhenAnyKeyWasRefused() async throws {
        try await withService(behaviour: .init(deleteRefusedKeys: ["dir/2.txt"])) { service, server in
            server.store.put(Data("1".utf8), forKey: "dir/1.txt")
            server.store.put(Data("2".utf8), forKey: "dir/2.txt")
            do {
                try await service.deleteDirectory(at: "/dir")
                Issue.record("expected the delete to report the refused key")
            } catch RemoteFileServiceError.permissionDenied {
            }
            #expect(server.store.object(forKey: "dir/2.txt") != nil)
        }
    }

    @Test
    func aMoveKeepsTheSourceWhenItsDeleteWasRefused() async throws {
        try await withService(behaviour: .init(deleteRefusedKeys: ["dir/2.txt"])) { service, server in
            server.store.put(Data("1".utf8), forKey: "dir/1.txt")
            server.store.put(Data("2".utf8), forKey: "dir/2.txt")
            await #expect(throws: RemoteFileServiceError.self) {
                try await service.moveItem(from: "/dir", to: "/moved")
            }
            // Copied in full first, so the refused source is still backed up.
            #expect(server.store.object(forKey: "moved/2.txt")?.data == Data("2".utf8))
            #expect(server.store.object(forKey: "dir/2.txt") != nil)
        }
    }

    // MARK: - Objects too large for one CopyObject

    @Test
    func anObjectOverTheCopyLimitIsMovedInRanges() async throws {
        let limit = 50
        try await withService(
            behaviour: .init(maxCopySourceBytes: limit),
            singleCopyLimitBytes: Int64(limit), copyPartSizeBytes: 40
        ) { service, server in
            let payload = Data((0..<130).map { UInt8($0 % 251) })
            server.store.put(payload, forKey: "huge.bin")

            try await service.moveItem(from: "/huge.bin", to: "/moved.bin")

            #expect(server.store.object(forKey: "moved.bin")?.data == payload)
            #expect(server.store.object(forKey: "huge.bin") == nil)
            #expect(server.store.openUploadCount == 0)
        }
    }

    @Test
    func anObjectOverTheLimitFailsCleanlyWhenTheServerRefusesTheCopy() async throws {
        // The client's threshold is higher than the server's, standing in for
        // a service with a lower limit than the client assumes.
        try await withService(behaviour: .init(maxCopySourceBytes: 10)) { service, server in
            server.store.put(Data(repeating: 1, count: 30), forKey: "huge.bin")
            await #expect(throws: RemoteFileServiceError.self) {
                try await service.moveItem(from: "/huge.bin", to: "/moved.bin")
            }
            #expect(server.store.object(forKey: "huge.bin") != nil)
        }
    }
}

private final class UploadSizesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var sizes: (multipartThresholdBytes: Int, partSizeBytes: Int)

    init(threshold: Int, partSize: Int) {
        sizes = (threshold, partSize)
    }

    var current: (multipartThresholdBytes: Int, partSizeBytes: Int) { lock.withLock { sizes } }

    func set(threshold: Int, partSize: Int) {
        lock.withLock { sizes = (threshold, partSize) }
    }
}
