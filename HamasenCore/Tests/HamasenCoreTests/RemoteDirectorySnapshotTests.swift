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

@Suite("RemoteDirectorySnapshot")
struct RemoteDirectorySnapshotTests {
    private let server = UUID()

    private func file(_ name: String, size: Int64 = 10, modified: TimeInterval = 1_000) -> RemoteItem {
        RemoteItem(
            path: RemotePath.join("/docs", name), name: name, kind: .file, size: size,
            modificationDate: Date(timeIntervalSince1970: modified))
    }

    private func folder(_ name: String, modified: TimeInterval = 1_000) -> RemoteItem {
        RemoteItem(
            path: RemotePath.join("/docs", name), name: name, kind: .directory, size: 0,
            modificationDate: Date(timeIntervalSince1970: modified))
    }

    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("remote-directories-\(UUID().uuidString)")
    }

    private func makeStore() -> RemoteDirectorySnapshotStore {
        RemoteDirectorySnapshotStore(directoryURL: makeRoot())
    }

    private func record(
        _ items: [RemoteItem], into store: RemoteDirectorySnapshotStore, serverID: UUID? = nil, path: String = "/docs"
    ) throws -> RemoteDirectorySnapshot.Change {
        try store.record(items, serverID: serverID ?? server, directoryPath: path)
    }

    /// Everything in a folder is new to the record the first time it is seen
    /// and none of it is new to the server. Announcing it all is how a
    /// notification becomes something people turn off.
    @Test
    func theFirstListingOfADirectoryReportsNothing() throws {
        let store = makeStore()
        let change = try record([file("a.txt"), file("b.txt")], into: store)
        #expect(change.isEmpty)
        #expect(store.snapshot(serverID: server, directoryPath: "/docs")?.entries.count == 2)
    }

    @Test
    func reportsWhatAppeared() throws {
        let store = makeStore()
        _ = try record([file("a.txt")], into: store)
        let change = try record([file("a.txt"), file("b.txt")], into: store)
        #expect(change.addedNames == ["b.txt"])
        #expect(change.updatedNames.isEmpty)
        #expect(change.removedNames.isEmpty)
    }

    @Test
    func reportsWhatWasEditedAndWhatWent() throws {
        let store = makeStore()
        _ = try record([file("a.txt", size: 10), file("gone.txt")], into: store)
        let change = try record([file("a.txt", size: 99)], into: store)
        #expect(change.updatedNames == ["a.txt"])
        #expect(change.removedNames == ["gone.txt"])
        #expect(change.totalCount == 2)
    }

    /// A file edited in place keeps its size often enough that size alone
    /// would miss it.
    @Test
    func aFileEditedWithoutChangingSizeIsStillAChange() throws {
        let store = makeStore()
        _ = try record([file("a.txt", size: 10, modified: 1_000)], into: store)
        let change = try record([file("a.txt", size: 10, modified: 2_000)], into: store)
        #expect(change.updatedNames == ["a.txt"])
    }

    @Test
    func nothingChangedIsReportedAsNothing() throws {
        let store = makeStore()
        _ = try record([file("a.txt"), folder("sub")], into: store)
        #expect(try record([file("a.txt"), folder("sub")], into: store).isEmpty)
    }

    /// The File Provider item version and this record must agree on what a
    /// change is; a listing that differs from a lookup only in the
    /// sub-second part of the time is not one.
    @Test
    func aFilesTokenIsTheSharedContentVersion() {
        let listed = file("a.txt", modified: 1_000.9)
        let looked = file("a.txt", modified: 1_000.1)
        #expect(RemoteDirectorySnapshot.token(for: listed) == RemoteDirectorySnapshot.token(for: looked))
        #expect(RemoteDirectorySnapshot.token(for: listed).hasSuffix(listed.contentVersionToken))

        let tagged = RemoteItem(path: "/docs/a.txt", name: "a.txt", kind: .file, size: 10, contentTag: "etag-1")
        let retagged = RemoteItem(path: "/docs/a.txt", name: "a.txt", kind: .file, size: 10, contentTag: "etag-2")
        #expect(RemoteDirectorySnapshot.token(for: tagged) != RemoteDirectorySnapshot.token(for: retagged))
    }

    /// Servers report a directory's size inconsistently, and one that
    /// "changed" on every listing would announce itself forever.
    @Test
    func aDirectorySizeIsNotPartOfItsToken() {
        let small = RemoteItem(path: "/docs/sub", name: "sub", kind: .directory, size: 0,
                               modificationDate: Date(timeIntervalSince1970: 1_000))
        let large = RemoteItem(path: "/docs/sub", name: "sub", kind: .directory, size: 4_096,
                               modificationDate: Date(timeIntervalSince1970: 1_000))
        #expect(RemoteDirectorySnapshot.token(for: small)
            == RemoteDirectorySnapshot.token(for: large))
    }

    /// A file and a directory of the same name are not the same thing, even
    /// if every other field matches.
    @Test
    func aFileAndADirectoryOfOneNameHaveDifferentTokens() {
        let asFile = RemoteItem(path: "/docs/x", name: "x", kind: .file, size: 0,
                                modificationDate: Date(timeIntervalSince1970: 1_000))
        let asFolder = RemoteItem(path: "/docs/x", name: "x", kind: .directory, size: 0,
                                  modificationDate: Date(timeIntervalSince1970: 1_000))
        #expect(RemoteDirectorySnapshot.token(for: asFile)
            != RemoteDirectorySnapshot.token(for: asFolder))
    }

    @Test
    func directoriesAreTrackedSeparatelyPerServerAndPath() throws {
        let store = makeStore()
        let other = UUID()
        _ = try record([file("a.txt")], into: store)
        _ = try record([file("a.txt")], into: store, serverID: other)
        _ = try record([file("a.txt")], into: store, path: "/other")

        let change = try record([], into: store, serverID: other)
        #expect(change.removedNames == ["a.txt"], "one server's listing must not touch another's")
        #expect(store.snapshot(serverID: server, directoryPath: "/docs")?.entries.count == 1)
        #expect(store.snapshot(serverID: server, directoryPath: "/other")?.entries.count == 1)
    }

    /// The file name is a hash of the path, so the path is kept inside and
    /// checked: a record for another path must never answer for this one.
    @Test
    func aRecordStoresItsPathAndAnswersOnlyForIt() throws {
        let store = makeStore()
        _ = try record([file("a.txt")], into: store, path: "/docs/日本語 folder")
        #expect(store.snapshot(serverID: server, directoryPath: "/docs/日本語 folder")?.path == "/docs/日本語 folder")
        #expect(store.snapshot(serverID: server, directoryPath: "/docs") == nil)
    }

    /// Left behind, an unmounted server's directories would all be reported
    /// as new the next time it came back.
    @Test
    func forgettingAServerDropsOnlyItsDirectories() throws {
        let store = makeStore()
        let other = UUID()
        _ = try record([file("a.txt")], into: store)
        _ = try record([file("a.txt")], into: store, serverID: other)
        try store.forget(serverID: server)
        #expect(store.snapshot(serverID: server, directoryPath: "/docs") == nil)
        #expect(store.snapshot(serverID: other, directoryPath: "/docs") != nil)
    }

    @Test
    func keepingOnlyMountedServersDropsTheRest() throws {
        let store = makeStore()
        let other = UUID()
        _ = try record([file("a.txt")], into: store)
        _ = try record([file("a.txt")], into: store, serverID: other)
        try store.keepOnly(serverIDs: [other])
        #expect(store.snapshot(serverID: server, directoryPath: "/docs") == nil)
        #expect(store.snapshot(serverID: other, directoryPath: "/docs") != nil)
    }

    @Test
    func keepingOnlyOnAnEmptyStoreIsNotAnError() throws {
        try makeStore().keepOnly(serverIDs: [server])
    }

    // MARK: - The poll

    /// The poll must leave the record for the extension to write when it
    /// brings the system up to date; otherwise the extension has no deletion
    /// left to report.
    @Test
    func observingDoesNotReplaceARecord() throws {
        let store = makeStore()
        _ = try record([file("a.txt"), file("gone.txt")], into: store)
        let change = try store.observe([file("a.txt")], serverID: server, directoryPath: "/docs")
        #expect(change.removedNames == ["gone.txt"])
        #expect(store.snapshot(serverID: server, directoryPath: "/docs")?.entries.count == 2)
    }

    @Test
    func observingADirectoryWithNoRecordGivesItABaseline() throws {
        let store = makeStore()
        let first = try store.observe([file("a.txt")], serverID: server, directoryPath: "/docs")
        #expect(first.isEmpty)
        #expect(store.snapshot(serverID: server, directoryPath: "/docs")?.entries.count == 1)
        let second = try store.observe([file("a.txt"), file("b.txt")], serverID: server, directoryPath: "/docs")
        #expect(second.addedNames == ["b.txt"])
    }

    // MARK: - Pruning

    @Test
    func pruningDropsOnlyWhatWasNotSeenForTheRetention() throws {
        let root = makeRoot()
        let store = RemoteDirectorySnapshotStore(directoryURL: root)
        let stale = UUID()
        _ = try record([file("a.txt")], into: store, serverID: stale)
        _ = try record([file("a.txt")], into: store, path: "/recent")
        _ = try record([file("a.txt")], into: store, path: "/looked-at")

        // Everything of the stale server's is old; "/looked-at" is old too
        // until the poll observes it, which counts as being seen.
        let age = RemoteDirectorySnapshotStore.retention + 120
        for directory in [root.appendingPathComponent(stale.uuidString),
                          root.appendingPathComponent(server.uuidString)] {
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
                try FileManager.default.setAttributes(
                    [.modificationDate: Date().addingTimeInterval(-age)],
                    ofItemAtPath: directory.appendingPathComponent(name).path)
            }
        }
        _ = try store.observe([file("a.txt")], serverID: server, directoryPath: "/looked-at")
        _ = try record([file("a.txt")], into: store, path: "/recent")

        #expect(try store.prune() == 1)
        #expect(store.snapshot(serverID: stale, directoryPath: "/docs") == nil)
        #expect(store.snapshot(serverID: server, directoryPath: "/recent") != nil)
        #expect(store.snapshot(serverID: server, directoryPath: "/looked-at") != nil)
    }

    // MARK: - Other processes

    /// The app and the extension record the same server at once. Every
    /// writer's directory must survive, and none may see another's as its own.
    @Test
    func concurrentRecordsOfDifferentDirectoriesAllLand() async throws {
        let store = makeStore()
        let serverID = server
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask {
                    _ = try? store.record(
                        [RemoteItem(path: "/d\(index)/f", name: "f", kind: .file, size: Int64(index))],
                        serverID: serverID, directoryPath: "/d\(index)")
                }
            }
        }
        for index in 0..<40 {
            #expect(store.snapshot(serverID: server, directoryPath: "/d\(index)") != nil)
        }
    }

    @Test
    func theSingleFileRecordItReplacedIsDeletedOnFirstUse() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("group-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let legacy = container.appendingPathComponent(SharedConstants.legacyRemoteDirectorySnapshotFileName)
        try Data("{}".utf8).write(to: legacy)

        _ = RemoteDirectorySnapshotStore(containerURL: container)
        #expect(FileManager.default.fileExists(atPath: legacy.path) == false)
    }
}
