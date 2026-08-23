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

    private func record(
        _ items: [RemoteItem], into snapshot: inout RemoteDirectorySnapshot
    ) -> RemoteDirectorySnapshot.Change {
        snapshot.record(items, serverID: server, directoryPath: "/docs")
    }

    /// Everything in a folder is new to the record the first time it is seen
    /// and none of it is new to the server. Announcing it all is how a
    /// notification becomes something people turn off.
    @Test
    func theFirstListingOfADirectoryReportsNothing() {
        var snapshot = RemoteDirectorySnapshot()
        let change = record([file("a.txt"), file("b.txt")], into: &snapshot)
        #expect(change.isEmpty)
        #expect(snapshot.directoryCount == 1)
    }

    @Test
    func reportsWhatAppeared() {
        var snapshot = RemoteDirectorySnapshot()
        _ = record([file("a.txt")], into: &snapshot)
        let change = record([file("a.txt"), file("b.txt")], into: &snapshot)
        #expect(change.addedNames == ["b.txt"])
        #expect(change.updatedNames.isEmpty)
        #expect(change.removedNames.isEmpty)
    }

    @Test
    func reportsWhatWasEditedAndWhatWent() {
        var snapshot = RemoteDirectorySnapshot()
        _ = record([file("a.txt", size: 10), file("gone.txt")], into: &snapshot)
        let change = record([file("a.txt", size: 99)], into: &snapshot)
        #expect(change.updatedNames == ["a.txt"])
        #expect(change.removedNames == ["gone.txt"])
        #expect(change.totalCount == 2)
    }

    /// A file edited in place keeps its size often enough that size alone
    /// would miss it.
    @Test
    func aFileEditedWithoutChangingSizeIsStillAChange() {
        var snapshot = RemoteDirectorySnapshot()
        _ = record([file("a.txt", size: 10, modified: 1_000)], into: &snapshot)
        let change = record([file("a.txt", size: 10, modified: 2_000)], into: &snapshot)
        #expect(change.updatedNames == ["a.txt"])
    }

    @Test
    func nothingChangedIsReportedAsNothing() {
        var snapshot = RemoteDirectorySnapshot()
        _ = record([file("a.txt"), folder("sub")], into: &snapshot)
        #expect(record([file("a.txt"), folder("sub")], into: &snapshot).isEmpty)
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
    func directoriesAreTrackedSeparatelyPerServerAndPath() {
        var snapshot = RemoteDirectorySnapshot()
        let other = UUID()
        _ = snapshot.record([file("a.txt")], serverID: server, directoryPath: "/docs")
        _ = snapshot.record([file("a.txt")], serverID: other, directoryPath: "/docs")
        _ = snapshot.record([file("a.txt")], serverID: server, directoryPath: "/other")
        #expect(snapshot.directoryCount == 3)

        let change = snapshot.record([], serverID: other, directoryPath: "/docs")
        #expect(change.removedNames == ["a.txt"], "one server's listing must not touch another's")
        #expect(snapshot.entries(serverID: server, directoryPath: "/docs")?.count == 1)
    }

    /// Left behind, an unmounted server's directories would all be reported
    /// as new the next time it came back.
    @Test
    func forgettingAServerDropsOnlyItsDirectories() {
        var snapshot = RemoteDirectorySnapshot()
        let other = UUID()
        _ = snapshot.record([file("a.txt")], serverID: server, directoryPath: "/docs")
        _ = snapshot.record([file("a.txt")], serverID: other, directoryPath: "/docs")
        snapshot.forget(serverID: server)
        #expect(snapshot.directoryCount == 1)
        #expect(snapshot.entries(serverID: other, directoryPath: "/docs") != nil)
    }

    @Test
    func keepingOnlyMountedServersDropsTheRest() {
        var snapshot = RemoteDirectorySnapshot()
        let other = UUID()
        _ = snapshot.record([file("a.txt")], serverID: server, directoryPath: "/docs")
        _ = snapshot.record([file("a.txt")], serverID: other, directoryPath: "/docs")
        snapshot.keepOnly(serverIDs: [other])
        #expect(snapshot.entries(serverID: server, directoryPath: "/docs") == nil)
        #expect(snapshot.entries(serverID: other, directoryPath: "/docs") != nil)
    }

    @Test
    func theSnapshotRoundTrips() throws {
        var snapshot = RemoteDirectorySnapshot()
        _ = record([file("a.txt"), folder("sub")], into: &snapshot)
        let decoded = try JSONDecoder().decode(
            RemoteDirectorySnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)
    }
}
