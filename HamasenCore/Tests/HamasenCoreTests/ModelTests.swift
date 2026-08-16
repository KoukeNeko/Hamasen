import Foundation
import Testing
@testable import HamasenCore

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

    @Test("舊版設定檔沒有認證方式欄位時解為密碼認證")
    func decodesLegacyConfigWithoutAuthenticationMethod() throws {
        let legacyJSON = """
        {
          "id": "6E1B2C1E-4E4B-4C0E-9E4A-2F5B6D7C8A90",
          "name": "企劃端的ftp",
          "transferProtocol": "sftp",
          "host": "sftpd.example.com",
          "port": 2222,
          "username": "user",
          "remotePath": "/"
        }
        """
        let config = try JSONDecoder().decode(ServerConfig.self, from: Data(legacyJSON.utf8))
        #expect(config.authenticationMethod == .password)
        #expect(config.name == "企劃端的ftp")
        #expect(config.port == 2222)
    }

    @Test("Codable round-trip")
    func codableRoundTrip() throws {
        let original = ServerConfig(
            name: "我的 NAS",
            host: "nas.local",
            port: 2222,
            username: "doeshing",
            authenticationMethod: .privateKey,
            remotePath: "/volume1/homes"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ServerConfig.self, from: data)
        #expect(decoded == original)
    }
}

@Suite("AppSettings")
struct AppSettingsTests {
    private func makeEphemeralStore() -> UserDefaults {
        let suiteName = "test-settings-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suiteName)!
        store.removePersistentDomain(forName: suiteName)
        return store
    }

    @Test("連線逾時：未設定與超出範圍時回預設值")
    func connectTimeoutFallsBackToDefault() {
        let store = makeEphemeralStore()
        #expect(AppSettings.connectTimeoutSeconds(from: store) == AppSettings.defaultConnectTimeoutSeconds)

        store.set(2, forKey: AppSettings.Keys.connectTimeoutSeconds)
        #expect(AppSettings.connectTimeoutSeconds(from: store) == AppSettings.defaultConnectTimeoutSeconds)

        store.set(60, forKey: AppSettings.Keys.connectTimeoutSeconds)
        #expect(AppSettings.connectTimeoutSeconds(from: store) == 60)
    }

    @Test("預設連接埠：無效值回 22")
    func defaultPortFallsBackToSFTPPort() {
        let store = makeEphemeralStore()
        #expect(AppSettings.defaultServerPort(from: store) == ServerConfig.defaultSFTPPort)

        store.set(2222, forKey: AppSettings.Keys.defaultServerPort)
        #expect(AppSettings.defaultServerPort(from: store) == 2222)

        store.set(0, forKey: AppSettings.Keys.defaultServerPort)
        #expect(AppSettings.defaultServerPort(from: store) == ServerConfig.defaultSFTPPort)
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

    @Test("移除掛載會寫回並回傳剩餘集合；不存在的 ID 不改動")
    func removeMountedServerPersistsRemainder() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mounted-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let store = MountedServersStore(fileURL: fileURL)
        let removedID = UUID()
        let keptID = UUID()
        try store.saveMountedServerIDs([removedID, keptID])

        #expect(try store.removeMountedServer(removedID) == [keptID])
        #expect(try store.loadMountedServerIDs() == [keptID])

        #expect(try store.removeMountedServer(UUID()) == [keptID])
        #expect(try store.loadMountedServerIDs() == [keptID])
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
