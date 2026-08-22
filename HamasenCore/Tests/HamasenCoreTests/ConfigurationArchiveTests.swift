import Foundation
import Testing
@testable import HamasenCore

@Suite("ConfigurationArchive")
struct ConfigurationArchiveTests {
    private static func server(
        _ name: String,
        host: String = "files.example.com",
        username: String = "doeshing"
    ) -> ServerConfig {
        ServerConfig(
            name: name,
            transferProtocol: .sftp,
            host: host,
            port: 2222,
            username: username,
            remotePath: "/srv"
        )
    }

    private static func archive(
        servers: [ServerConfig],
        knownHosts: KnownHosts = KnownHosts()
    ) -> ConfigurationArchive {
        ConfigurationArchive(
            exportedAt: Date(timeIntervalSince1970: 1_767_225_600),
            servers: servers,
            knownHosts: knownHosts,
            settings: ConfigurationArchive.Settings(connectTimeoutSeconds: 45, defaultServerPort: 2222)
        )
    }

    @Test("寫出再讀回內容一致")
    func roundTripsThroughJSON() throws {
        let original = Self.archive(
            servers: [Self.server("工作站")],
            knownHosts: KnownHosts(fingerprintsByEndpoint: ["files.example.com:2222": "SHA256:AAAA"])
        )
        let restored = try ConfigurationArchive.decoded(from: original.encoded())
        #expect(restored == original)
    }

    @Test("設定會一起帶走")
    func carriesTheSettings() throws {
        let restored = try ConfigurationArchive.decoded(from: Self.archive(servers: []).encoded())
        #expect(restored.settings.connectTimeoutSeconds == 45)
        #expect(restored.settings.defaultServerPort == 2222)
    }

    @Test("不是備份檔就明確拒絕")
    func rejectsSomethingElse() {
        #expect(throws: ConfigurationArchive.ArchiveError.unreadable) {
            try ConfigurationArchive.decoded(from: Data("not an archive".utf8))
        }
    }

    /// Reading half of a newer file would be worse than reading none of it.
    @Test("較新版本的備份會被拒絕，而不是讀一半")
    func rejectsANewerVersion() throws {
        var json = try JSONSerialization.jsonObject(
            with: Self.archive(servers: []).encoded()
        ) as! [String: Any]
        json["version"] = ConfigurationArchive.currentVersion + 1
        let data = try JSONSerialization.data(withJSONObject: json)

        #expect(throws: ConfigurationArchive.ArchiveError.self) {
            try ConfigurationArchive.decoded(from: data)
        }
    }

    // MARK: - Merging

    @Test("匯入會加進既有清單，而不是取代它")
    func addsToWhatIsAlreadyThere() {
        let existing = [Self.server("既有", host: "other.example.com")]
        let plan = Self.archive(servers: [Self.server("備份裡的")])
            .mergePlan(against: existing, existingHosts: KnownHosts())

        #expect(plan.servers.count == 1)
        #expect(plan.servers.first?.name == "備份裡的")
        #expect(plan.duplicateCount == 0)
    }

    @Test("已經設定過的連線會被略過")
    func skipsServersAlreadyConfigured() {
        let existing = [Self.server("名字不同但同一台")]
        let plan = Self.archive(servers: [Self.server("備份裡的")])
            .mergePlan(against: existing, existingHosts: KnownHosts())

        #expect(plan.servers.isEmpty)
        #expect(plan.duplicateCount == 1)
    }

    /// Restoring the same file twice must not produce two servers sharing an
    /// identifier, which is what everything else keys off.
    @Test("重複匯入不會產生相同識別碼")
    func givesEveryRestoredServerItsOwnIdentifier() {
        let archive = Self.archive(servers: [Self.server("工作站")])
        let first = archive.mergePlan(against: [], existingHosts: KnownHosts())
        let second = archive.mergePlan(against: [], existingHosts: KnownHosts())

        #expect(first.servers.first?.id != second.servers.first?.id)
        #expect(first.servers.first?.id != archive.servers.first?.id)
    }

    @Test("備份裡的主機金鑰會補進來")
    func addsHostKeysItKnowsAbout() {
        let plan = Self.archive(
            servers: [],
            knownHosts: KnownHosts(fingerprintsByEndpoint: ["a.example.com:22": "SHA256:AAAA"])
        ).mergePlan(against: [], existingHosts: KnownHosts())

        #expect(plan.knownHosts.fingerprint(forEndpoint: "a.example.com:22") == "SHA256:AAAA")
    }

    /// Otherwise restoring a backup would be a way around a key that stopped
    /// matching — which is the one thing host key checking exists to catch.
    @Test("備份不會覆寫已經記錄的主機金鑰")
    func neverReplacesARecordedHostKey() {
        let plan = Self.archive(
            servers: [],
            knownHosts: KnownHosts(fingerprintsByEndpoint: ["a.example.com:22": "SHA256:FROMBACKUP"])
        ).mergePlan(
            against: [],
            existingHosts: KnownHosts(fingerprintsByEndpoint: ["a.example.com:22": "SHA256:ALREADYHERE"])
        )

        #expect(plan.knownHosts.fingerprint(forEndpoint: "a.example.com:22") == "SHA256:ALREADYHERE")
    }

    /// Pins what a server entry is allowed to contain, rather than searching
    /// the text for words that look like secrets — "password" appears
    /// legitimately as the name of an authentication method. A field added
    /// later that could carry a secret fails here.
    @Test("備份裡的伺服器欄位就是這些，不多不少")
    func writesOnlyTheFieldsItShould() throws {
        let data = try Self.archive(servers: [Self.server("工作站")]).encoded()
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let servers = try #require(json["servers"] as? [[String: Any]])
        let entry = try #require(servers.first)

        #expect(
            Set(entry.keys) == [
                "id",
                "name",
                "transferProtocol",
                "host",
                "port",
                "username",
                "authenticationMethod",
                "remotePath",
                "storageMode",
            ]
        )
    }
}
