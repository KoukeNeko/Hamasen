import Foundation
import Testing
@testable import HamasenCore

/// Exercises host key checking against a real SSH handshake, which is the
/// only place the fingerprint, the record and the refusal meet.
@Suite("HostKeyPolicy")
struct HostKeyPolicyTests {
    private static func makeStore() -> KnownHostsStore {
        KnownHostsStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("known-hosts-\(UUID().uuidString).json")
        )
    }

    private static func makeService(
        port: Int,
        policy: HostKeyPolicy
    ) -> SFTPFileService {
        SFTPFileService(
            config: ServerConfig(
                name: "測試伺服器",
                host: "127.0.0.1",
                port: port,
                username: TestSFTPServer.username
            ),
            credentials: .password(TestSFTPServer.password),
            hostKeyPolicy: policy
        )
    }

    @Test("首次連線會記下主機金鑰")
    func recordsTheKeyOnFirstConnection() async throws {
        let server = try await TestSFTPServer.start()
        let store = Self.makeStore()
        let endpoint = KnownHosts.endpoint(host: "127.0.0.1", port: server.port)

        #expect(try store.load().fingerprint(forEndpoint: endpoint) == nil)

        let service = Self.makeService(port: server.port, policy: .trustOnFirstUse(store))
        try await service.connect()
        try await service.disconnect()

        let recorded = try #require(try store.load().fingerprint(forEndpoint: endpoint))
        #expect(recorded.hasPrefix("SHA256:"))
        try await server.stop()
    }

    @Test("同一把金鑰再次連線不受影響")
    func acceptsTheSameKeyAgain() async throws {
        let server = try await TestSFTPServer.start()
        let store = Self.makeStore()

        for _ in 0..<2 {
            let service = Self.makeService(port: server.port, policy: .trustOnFirstUse(store))
            try await service.connect()
            try await service.disconnect()
        }

        try await server.stop()
    }

    /// The reason the whole thing exists: a key that is not the one recorded
    /// stops the connection instead of going through unnoticed.
    @Test("金鑰與記錄不符時中止連線，並說出兩邊的指紋")
    func refusesAKeyThatDoesNotMatchTheRecord() async throws {
        let server = try await TestSFTPServer.start()
        let store = Self.makeStore()
        let endpoint = KnownHosts.endpoint(host: "127.0.0.1", port: server.port)
        try store.save(KnownHosts(fingerprintsByEndpoint: [endpoint: "SHA256:somethingelse"]))

        let service = Self.makeService(port: server.port, policy: .trustOnFirstUse(store))
        do {
            try await service.connect()
            Issue.record("連線應該被拒絕")
        } catch let error as RemoteFileServiceError {
            guard case .hostKeyChanged(let failedEndpoint, let recorded, let presented) = error else {
                Issue.record("預期 hostKeyChanged，得到 \(error)")
                try await server.stop()
                return
            }
            #expect(failedEndpoint == endpoint)
            #expect(recorded == "SHA256:somethingelse")
            #expect(presented.hasPrefix("SHA256:"))
            #expect(presented != recorded)
        }

        // The refusal must not quietly adopt what it just refused.
        #expect(try store.load().fingerprint(forEndpoint: endpoint) == "SHA256:somethingelse")
        try await server.stop()
    }

    @Test("忘記端點後可以重新記錄新的金鑰")
    func forgettingLetsARebuiltServerBeTrustedAgain() async throws {
        let server = try await TestSFTPServer.start()
        let store = Self.makeStore()
        let endpoint = KnownHosts.endpoint(host: "127.0.0.1", port: server.port)
        try store.save(KnownHosts(fingerprintsByEndpoint: [endpoint: "SHA256:somethingelse"]))
        try store.forget(endpoint: endpoint)

        let service = Self.makeService(port: server.port, policy: .trustOnFirstUse(store))
        try await service.connect()
        try await service.disconnect()

        #expect(try store.load().fingerprint(forEndpoint: endpoint) != "SHA256:somethingelse")
        try await server.stop()
    }

    /// Failing open would make an unreadable record indistinguishable from a
    /// verified connection.
    @Test("無法讀取記錄時拒絕連線，而不是放行")
    func refusesToConnectWhenTheRecordCannotBeRead() async throws {
        let server = try await TestSFTPServer.start()
        let service = Self.makeService(
            port: server.port,
            policy: .unverifiable(reason: "測試用的無法讀取")
        )

        await #expect(throws: RemoteFileServiceError.self) {
            try await service.connect()
        }
        try await server.stop()
    }
}
