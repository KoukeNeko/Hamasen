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

@Suite("S3FileService")
struct S3FileServiceTests {
    private static func config(remotePath: String = "/\(TestS3Server.bucket)") -> ServerConfig {
        ServerConfig(
            name: "測試 S3",
            transferProtocol: .s3,
            host: "127.0.0.1",
            port: 443,
            username: TestS3Server.credentials.accessKeyID,
            remotePath: remotePath)
    }

    private func withService(
        behaviour: TestS3Server.Behaviour = .wellBehaved,
        remotePath: String = "/\(TestS3Server.bucket)",
        secret: String = TestS3Server.credentials.secretAccessKey,
        multipartThresholdBytes: Int = S3FileService.Upload.defaultMultipartThresholdBytes,
        partSizeBytes: Int = S3FileService.Upload.defaultPartSizeBytes,
        connect: Bool = true,
        _ work: (S3FileService, TestS3Server) async throws -> Void
    ) async throws {
        let server = try await TestS3Server.start(behaviour: behaviour)
        let service = S3FileService(
            config: Self.config(remotePath: remotePath),
            credentials: .password(secret),
            endpoint: server.endpoint,
            multipartThresholdBytes: multipartThresholdBytes,
            partSizeBytes: partSizeBytes)
        do {
            if connect { try await service.connect() }
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
            .appendingPathComponent("s3-test-\(UUID().uuidString)")
        try contents.write(to: url)
        return url
    }

    private func seed(_ server: TestS3Server) {
        for key in ["report.pdf", "photos/", "photos/1.jpg", "photos/2.jpg",
                    "photos/raw/3.dng", "notes/x.md"] {
            server.store.put(Data(key.utf8), forKey: key)
        }
    }

    // MARK: - Connecting

    @Test
    func connectsAndReportsItself() async throws {
        try await withService { service, _ in
            #expect(await service.isConnected)
        }
    }

    @Test
    func refusesTheWrongSecret() async throws {
        await #expect(throws: RemoteFileServiceError.authenticationFailed) {
            try await withService(secret: "not-the-secret", connect: false) { service, _ in
                try await service.connect()
            }
        }
    }

    /// An SSH key is not something this protocol can use, and saying so is
    /// better than a signature failure the user cannot interpret.
    @Test
    func refusesAnSSHKey() async throws {
        let server = try await TestS3Server.start()
        let service = S3FileService(
            config: Self.config(),
            credentials: .privateKey(openSSHKey: "irrelevant", passphrase: nil),
            endpoint: server.endpoint)
        await #expect(throws: RemoteFileServiceError.unsupportedCredentials(protocolName: "S3")) {
            try await service.connect()
        }
        try await server.stop()
    }

    // MARK: - Listing

    @Test
    func listsTheBucketRoot() async throws {
        try await withService { service, server in
            seed(server)
            let items = try await service.listDirectory(at: RemotePath.root)
            #expect(items.map(\.name) == ["notes", "photos", "report.pdf"])
            #expect(items.filter(\.isDirectory).map(\.name) == ["notes", "photos"])
            #expect(items.map(\.path).sorted()
                == ["/notes", "/photos", "/report.pdf"])
        }
    }

    /// The zero-byte marker of an empty folder arrives as an object whose
    /// name after the prefix is empty. Left in, every folder would appear to
    /// contain a nameless file.
    @Test
    func hidesTheFolderMarker() async throws {
        try await withService { service, server in
            seed(server)
            let items = try await service.listDirectory(at: "/photos")
            #expect(items.map(\.name) == ["1.jpg", "2.jpg", "raw"])
        }
    }

    @Test
    func listsAcrossPages() async throws {
        try await withService(behaviour: TestS3Server.Behaviour(maxKeysPerPage: 2)) { service, server in
            for index in 0..<7 { server.store.put(Data(), forKey: "file-\(index).txt") }
            let items = try await service.listDirectory(at: RemotePath.root)
            #expect(items.count == 7)
            #expect(items.map(\.name) == (0..<7).map { "file-\($0).txt" })
        }
    }

    /// S3 keys are opaque, so "a" says nothing about "a/b" and both can
    /// exist. Finder cannot show one name twice; the object wins so that a
    /// lookup stays one request and agrees with `itemInfo`.
    @Test
    func showsTheObjectWhenANameIsAlsoAPrefix() async throws {
        try await withService { service, server in
            server.store.put(Data("file".utf8), forKey: "ambiguous")
            server.store.put(Data("child".utf8), forKey: "ambiguous/inside.txt")
            let items = try await service.listDirectory(at: RemotePath.root)
            #expect(items.map(\.name) == ["ambiguous"])
            #expect(items[0].isDirectory == false)

            let info = try await service.itemInfo(at: "/ambiguous")
            #expect(info.isDirectory == false)
        }
    }

    @Test
    func keepsPathsMountRelativeUnderAConfiguredPrefix() async throws {
        try await withService(remotePath: "/\(TestS3Server.bucket)/data") { service, server in
            server.store.put(Data("x".utf8), forKey: "data/a.txt")
            server.store.put(Data("y".utf8), forKey: "data/sub/b.txt")
            server.store.put(Data("z".utf8), forKey: "outside.txt")

            let items = try await service.listDirectory(at: RemotePath.root)
            #expect(items.map(\.path) == ["/a.txt", "/sub"])

            let nested = try await service.listDirectory(at: "/sub")
            #expect(nested.map(\.path) == ["/sub/b.txt"])
        }
    }

    // MARK: - Item information

    @Test
    func readsAFilesSizeAndDate() async throws {
        try await withService { service, server in
            let when = Date(timeIntervalSince1970: 1_787_458_500)
            server.store.put(Data("0123456789".utf8), forKey: "n.txt", modifiedAt: when)
            let info = try await service.itemInfo(at: "/n.txt")
            #expect(info.kind == .file)
            #expect(info.size == 10)
            #expect(info.modificationDate == when)
        }
    }

    @Test
    func recognisesAFolderThatIsOnlyAPrefix() async throws {
        try await withService { service, server in
            server.store.put(Data(), forKey: "photos/1.jpg")
            let info = try await service.itemInfo(at: "/photos")
            #expect(info.kind == .directory)
            #expect(info.name == "photos")
        }
    }

    @Test
    func theMountRootIsADirectoryWithoutAsking() async throws {
        try await withService { service, _ in
            let root = try await service.itemInfo(at: RemotePath.root)
            #expect(root.kind == .directory)
        }
    }

    @Test
    func reportsSomethingMissingAsNotFound() async throws {
        try await withService { service, _ in
            await #expect(throws: RemoteFileServiceError.itemNotFound(path: "/nope.txt")) {
                try await service.itemInfo(at: "/nope.txt")
            }
        }
    }

    // MARK: - Downloading

    @Test
    func downloadsAWholeFile() async throws {
        try await withService { service, server in
            let payload = Data("哈瑪星 contents".utf8)
            server.store.put(payload, forKey: "docs/a.txt")
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("s3-download-\(UUID().uuidString)")
            try await service.downloadFile(at: "/docs/a.txt", to: destination)
            let written = try Data(contentsOf: destination)
            #expect(written == payload)
            try? FileManager.default.removeItem(at: destination)
        }
    }

    @Test
    func downloadsAByteRange() async throws {
        try await withService { service, server in
            server.store.put(Data("0123456789".utf8), forKey: "n.txt")
            let middle = try await service.downloadRange(at: "/n.txt", offset: 2, length: 4)
            #expect(middle == Data("2345".utf8))
            let tail = try await service.downloadRange(at: "/n.txt", offset: 7, length: 99)
            #expect(tail == Data("789".utf8))
        }
    }

    /// Fewer bytes than asked for is the documented answer when the range
    /// runs past the end, and none is how many are there.
    @Test
    func aRangePastTheEndIsEmpty() async throws {
        try await withService { service, server in
            server.store.put(Data("012".utf8), forKey: "n.txt")
            let beyond = try await service.downloadRange(at: "/n.txt", offset: 10, length: 4)
            #expect(beyond.isEmpty)
        }
    }

    // MARK: - Uploading

    @Test
    func uploadsASmallFileInOneRequest() async throws {
        try await withService { service, server in
            let payload = Data("small".utf8)
            let source = try temporaryFile(payload)
            try await service.uploadFile(from: source, to: "/docs/a.txt")
            #expect(server.store.object(forKey: "docs/a.txt")?.data == payload)
            #expect(server.store.openUploadCount == 0)
            try? FileManager.default.removeItem(at: source)
        }
    }

    @Test
    func uploadsALargeFileInParts() async throws {
        try await withService(multipartThresholdBytes: 100, partSizeBytes: 40) { service, server in
            let payload = Data((0..<101).map { UInt8($0 % 251) })
            let source = try temporaryFile(payload)
            try await service.uploadFile(from: source, to: "/big.bin")
            #expect(server.store.object(forKey: "big.bin")?.data == payload)
            #expect(server.store.openUploadCount == 0)
            try? FileManager.default.removeItem(at: source)
        }
    }

    /// An upload left open keeps its parts, and the account is billed for
    /// them until somebody notices. Failing partway must abandon it.
    @Test
    func abandonsThePartsOfAFailedUpload() async throws {
        try await withService(
            behaviour: TestS3Server.Behaviour(failWritesAfter: 2),
            multipartThresholdBytes: 100, partSizeBytes: 40
        ) { service, server in
            let source = try temporaryFile(Data(repeating: 7, count: 101))
            await #expect(throws: (any Error).self) {
                try await service.uploadFile(from: source, to: "/big.bin")
            }
            #expect(server.store.openUploadCount == 0)
            #expect(server.store.object(forKey: "big.bin") == nil)
            try? FileManager.default.removeItem(at: source)
        }
    }

    // MARK: - Folders and deletion

    @Test
    func createsAFolderAsAMarkerObject() async throws {
        try await withService { service, server in
            try await service.createDirectory(at: "/empty")
            #expect(server.store.object(forKey: "empty/")?.data.isEmpty == true)
            let items = try await service.listDirectory(at: RemotePath.root)
            #expect(items.map(\.name) == ["empty"])
            #expect(items[0].isDirectory)
        }
    }

    @Test
    func deletesAFile() async throws {
        try await withService { service, server in
            server.store.put(Data("x".utf8), forKey: "a.txt")
            try await service.deleteFile(at: "/a.txt")
            #expect(server.store.object(forKey: "a.txt") == nil)
        }
    }

    @Test
    func deletesAFolderAndEverythingUnderIt() async throws {
        try await withService { service, server in
            seed(server)
            try await service.deleteDirectory(at: "/photos")
            #expect(server.store.object(forKey: "photos/") == nil)
            #expect(server.store.object(forKey: "photos/1.jpg") == nil)
            #expect(server.store.object(forKey: "photos/raw/3.dng") == nil)
            #expect(server.store.object(forKey: "notes/x.md") != nil)
            #expect(server.store.object(forKey: "report.pdf") != nil)
        }
    }

    // MARK: - Moving

    @Test
    func movesAFileByCopyingThenDeleting() async throws {
        try await withService { service, server in
            server.store.put(Data("payload".utf8), forKey: "a.txt")
            try await service.moveItem(from: "/a.txt", to: "/b.txt")
            #expect(server.store.object(forKey: "b.txt")?.data == Data("payload".utf8))
            #expect(server.store.object(forKey: "a.txt") == nil)
        }
    }

    @Test
    func movesAFolderOneObjectAtATime() async throws {
        try await withService { service, server in
            seed(server)
            try await service.moveItem(from: "/photos", to: "/pictures")
            #expect(server.store.object(forKey: "pictures/1.jpg") != nil)
            #expect(server.store.object(forKey: "pictures/raw/3.dng") != nil)
            #expect(server.store.object(forKey: "photos/1.jpg") == nil)
            #expect(server.store.object(forKey: "photos/raw/3.dng") == nil)
            #expect(server.store.object(forKey: "notes/x.md") != nil)
        }
    }

    @Test
    func movingSomethingMissingIsReportedRatherThanSilentlyDoingNothing() async throws {
        try await withService { service, _ in
            await #expect(throws: RemoteFileServiceError.itemNotFound(path: "/nope")) {
                try await service.moveItem(from: "/nope", to: "/elsewhere")
            }
        }
    }

    // MARK: - Teardown

    @Test
    func stopsReportingConnectedAfterDisconnect() async throws {
        let server = try await TestS3Server.start()
        let service = S3FileService(
            config: Self.config(),
            credentials: .password(TestS3Server.credentials.secretAccessKey),
            endpoint: server.endpoint)
        try await service.connect()
        #expect(await service.isConnected)
        try await service.disconnect()
        #expect(await service.isConnected == false)
        await #expect(throws: RemoteFileServiceError.notConnected) {
            _ = try await service.listDirectory(at: RemotePath.root)
        }
        try await server.stop()
    }
}
