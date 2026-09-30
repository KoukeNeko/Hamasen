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

@Suite("ServerListChangeTracker")
struct ServerListChangeTrackerTests {
    private func makeServer(name: String, id: UUID = UUID()) -> ServerConfig {
        ServerConfig(id: id, name: name, host: "example.com", username: "user")
    }

    @Test("新增的伺服器列為更新")
    func detectsAddedServer() {
        let existing = makeServer(name: "企劃端的ftp")
        let added = makeServer(name: "web")
        let previous = ServerListChangeTracker.snapshot(of: [existing])

        let diff = ServerListChangeTracker.diff(previous: previous, current: [existing, added])

        #expect(diff.updated.map(\.name) == ["web"])
        #expect(diff.removedServerIDs.isEmpty)
    }

    @Test("卸載的伺服器列為刪除")
    func detectsRemovedServer() {
        let kept = makeServer(name: "web")
        let removed = makeServer(name: "舊伺服器")
        let previous = ServerListChangeTracker.snapshot(of: [kept, removed])

        let diff = ServerListChangeTracker.diff(previous: previous, current: [kept])

        #expect(diff.updated.isEmpty)
        #expect(diff.removedServerIDs == [removed.id.uuidString])
    }

    @Test("改名的伺服器列為更新")
    func detectsRenamedServer() {
        let serverID = UUID()
        let before = makeServer(name: "舊名字", id: serverID)
        let after = makeServer(name: "新名字", id: serverID)
        let previous = ServerListChangeTracker.snapshot(of: [before])

        let diff = ServerListChangeTracker.diff(previous: previous, current: [after])

        #expect(diff.updated.map(\.name) == ["新名字"])
        #expect(diff.removedServerIDs.isEmpty)
    }

    @Test("沒有變動時差異為空")
    func detectsNoChange() {
        let servers = [makeServer(name: "web"), makeServer(name: "nas")]
        let previous = ServerListChangeTracker.snapshot(of: servers)

        let diff = ServerListChangeTracker.diff(previous: previous, current: servers)

        #expect(diff.isEmpty)
    }

    @Test("同一份清單編碼結果穩定（順序無關）")
    func encodingIsStable() {
        let first = makeServer(name: "web")
        let second = makeServer(name: "nas")
        let forward = ServerListChangeTracker.encode(ServerListChangeTracker.snapshot(of: [first, second]))
        let reversed = ServerListChangeTracker.encode(ServerListChangeTracker.snapshot(of: [second, first]))

        #expect(forward == reversed)
    }

    @Test("編碼後可解回相同快照")
    func encodeDecodeRoundTrip() {
        let servers = [makeServer(name: "web"), makeServer(name: "nas")]
        let snapshot = ServerListChangeTracker.snapshot(of: servers)

        let decoded = ServerListChangeTracker.decode(ServerListChangeTracker.encode(snapshot))

        #expect(decoded == snapshot)
    }

    @Test("無法解讀的錨點視為全新，所有伺服器都是新增")
    func treatsUnreadableAnchorAsEmpty() {
        let servers = [makeServer(name: "web")]
        let previous = ServerListChangeTracker.decode(Data("not json".utf8))

        let diff = ServerListChangeTracker.diff(previous: previous, current: servers)

        #expect(diff.updated.count == 1)
    }
}

@Suite("ServerListChangeTracker storage mode")
struct ServerListChangeTrackerStorageModeTests {
    /// The storage mode decides the folder's content policy, so a change to
    /// it has to be reported: otherwise the system is never told to re-read
    /// the item and the old policy stays in force.
    @Test("改變儲存方式會被視為變更")
    func reportsStorageModeChange() {
        let server = ServerConfig(name: "NAS", host: "example.com", username: "user")
        let previous = ServerListChangeTracker.snapshot(of: [server])

        var switched = server
        switched.storageMode = .onlineOnly

        let diff = ServerListChangeTracker.diff(previous: previous, current: [switched])
        #expect(diff.updated.map(\.id) == [server.id])
    }

    @Test("沒有任何變更時不回報")
    func reportsNothingWhenUnchanged() {
        let server = ServerConfig(name: "NAS", host: "example.com", username: "user")
        let previous = ServerListChangeTracker.snapshot(of: [server])
        #expect(ServerListChangeTracker.diff(previous: previous, current: [server]).isEmpty)
    }
}

@Suite("Server list sync anchor")
struct ServerListSyncAnchorTests {
    private func servers(_ count: Int) -> [ServerConfig] {
        (0..<count).map {
            ServerConfig(name: "很長很長的伺服器名稱 \($0) 用來把錨點撐大", host: "example.com", username: "user")
        }
    }

    private func makeStore() -> ServerListSnapshotStore {
        ServerListSnapshotStore(directoryURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("server-lists-\(UUID().uuidString)"))
    }

    @Test("摘要與順序無關，內容不同則不同")
    func digestIsStableAndSensitive() {
        let list = servers(3)
        let forward = ServerListChangeTracker.digest(of: ServerListChangeTracker.snapshot(of: list))
        let reversed = ServerListChangeTracker.digest(of: ServerListChangeTracker.snapshot(of: list.reversed()))
        let fewer = ServerListChangeTracker.digest(of: ServerListChangeTracker.snapshot(of: Array(list.dropLast())))
        #expect(forward == reversed)
        #expect(forward != fewer)
    }

    /// The old anchor was the whole list, which passed 500 bytes at about
    /// seven servers and made the system re-import on every signal.
    @Test("錨點大小不隨伺服器數量增加")
    func anchorStaysSmallWhateverTheListSize() throws {
        let store = makeStore()
        let walk = WorkingSetWalk(serverIDs: [UUID()]).token
        for count in [0, 1, 7, 200] {
            let digest = try store.save(ServerListChangeTracker.snapshot(of: servers(count)))
            let anchor = WorkingSetAnchor(serverList: digest, walk: walk).encoded()
            #expect(anchor.count < 200, "\(count) servers gave \(anchor.count) bytes")
        }
    }

    @Test("錨點可以往返編碼，看不懂的錨點解不開")
    func anchorRoundTrips() {
        let anchor = WorkingSetAnchor(serverList: "abc", walk: WorkingSetWalk(serverIDs: []).token)
        #expect(WorkingSetAnchor.decode(anchor.encoded()) == anchor)
        #expect(WorkingSetAnchor.decode(WorkingSetAnchor(serverList: "abc", walk: nil).encoded())?.walk == nil)
        // What the anchor used to be: the list itself.
        #expect(WorkingSetAnchor.decode(ServerListChangeTracker.encode(["id": "name|mode"])) == nil)
        #expect(WorkingSetAnchor.decode(Data()) == nil)
    }

    @Test("儲存的快照可用摘要取回，找不到就是 nil 而非空清單")
    func snapshotIsFoundByDigest() throws {
        let store = makeStore()
        let snapshot = ServerListChangeTracker.snapshot(of: servers(3))
        let digest = try store.save(snapshot)
        #expect(store.load(digest: digest) == snapshot)
        #expect(store.load(digest: "0000") == nil)
        #expect(store.load(digest: "../../etc/passwd") == nil)

        let empty = try store.save([:])
        #expect(store.load(digest: empty) == [:], "an empty list is a list")
    }

    @Test("只保留最近幾份快照，最新的一份不會被丟掉")
    func onlyTheLatestSnapshotsAreKept() throws {
        let store = makeStore()
        var digests: [String] = []
        for count in 1...(ServerListSnapshotStore.keptCount + 3) {
            digests.append(try store.save(ServerListChangeTracker.snapshot(of: servers(count))))
            // File times are what age is judged by.
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(store.load(digest: digests.last!) != nil)
        #expect(store.load(digest: digests.first!) == nil)
        let stillThere = digests.filter { store.load(digest: $0) != nil }
        #expect(stillThere.count == ServerListSnapshotStore.keptCount)
    }
}
