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
