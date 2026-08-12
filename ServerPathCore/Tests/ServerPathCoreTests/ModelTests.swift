import Foundation
import Testing
@testable import ServerPathCore

@Suite("RemotePath")
struct RemotePathTests {
    @Test("join 組合根目錄與子路徑")
    func joinPaths() {
        #expect(RemotePath.join("/", "file.txt") == "/file.txt")
        #expect(RemotePath.join("/docs", "file.txt") == "/docs/file.txt")
    }

    @Test("parent 回傳上層目錄")
    func parentPaths() {
        #expect(RemotePath.parent(of: "/docs/file.txt") == "/docs")
        #expect(RemotePath.parent(of: "/file.txt") == "/")
        #expect(RemotePath.parent(of: "/") == "/")
    }

    @Test("name 取出最後一段")
    func namePaths() {
        #expect(RemotePath.name(of: "/docs/file.txt") == "file.txt")
        #expect(RemotePath.name(of: "/file.txt") == "file.txt")
    }
}

@Suite("ServerConfig")
struct ServerConfigTests {
    @Test("remotePath 正規化")
    func remotePathNormalization() {
        #expect(ServerConfig.normalizedRemotePath("") == "/")
        #expect(ServerConfig.normalizedRemotePath("/data/") == "/data")
        #expect(ServerConfig.normalizedRemotePath("data") == "/data")
        #expect(ServerConfig.normalizedRemotePath("/") == "/")
    }

    @Test("Codable round-trip")
    func codableRoundTrip() throws {
        let original = ServerConfig(
            name: "我的 NAS",
            host: "nas.local",
            port: 2222,
            username: "doeshing",
            remotePath: "/volume1/homes"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ServerConfig.self, from: data)
        #expect(decoded == original)
    }
}

@Suite("MountedServersStore")
struct MountedServersStoreTests {
    @Test("掛載集合儲存與讀回")
    func saveAndLoadRoundTrip() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mounted-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let store = MountedServersStore(fileURL: fileURL)
        #expect(try store.loadMountedServerIDs().isEmpty)

        let mountedIDs: Set<UUID> = [UUID(), UUID()]
        try store.saveMountedServerIDs(mountedIDs)
        #expect(try store.loadMountedServerIDs() == mountedIDs)
    }
}

@Suite("ServerConfigStore")
struct ServerConfigStoreTests {
    @Test("儲存後可讀回相同設定")
    func saveAndLoadRoundTrip() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("servers-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let store = ServerConfigStore(fileURL: fileURL)
        #expect(try store.loadServers().isEmpty)

        let servers = [
            ServerConfig(name: "A", host: "a.example.com", username: "user-a"),
            ServerConfig(name: "B", host: "b.example.com", port: 2222, username: "user-b"),
        ]
        try store.saveServers(servers)

        let loaded = try store.loadServers()
        #expect(loaded == servers)
        #expect(try store.server(withID: servers[0].id) == servers[0])
    }
}
