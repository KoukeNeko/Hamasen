import Foundation
import Testing
@testable import HamasenCore

@Suite("ProtectedConfigurationArchive")
struct ProtectedConfigurationArchiveTests {
    private static let serverID = UUID(uuidString: "D43D14AD-BDCD-4EED-9A5D-8E2B33127075")!

    private static func server(_ name: String, host: String = "files.example.com") -> ServerConfig {
        ServerConfig(
            id: serverID,
            name: name,
            transferProtocol: .sftp,
            host: host,
            port: 2222,
            username: "doeshing",
            remotePath: "/srv"
        )
    }

    private static func archive(servers: [ServerConfig]) -> ConfigurationArchive {
        ConfigurationArchive(
            exportedAt: Date(timeIntervalSince1970: 1_767_225_600),
            servers: servers,
            knownHosts: KnownHosts(),
            settings: ConfigurationArchive.Settings(connectTimeoutSeconds: 30, defaultServerPort: 22)
        )
    }

    private static func protected() -> ProtectedConfigurationArchive {
        ProtectedConfigurationArchive(
            configuration: archive(servers: [server("工作站")]),
            credentials: [
                .init(serverID: serverID, kind: "password", secret: "hunter2"),
            ]
        )
    }

    @Test("用同一個密碼可以還原設定與憑證")
    func roundTripsWithTheSamePassphrase() throws {
        let sealed = try Self.protected().sealed(passphrase: "correct horse")
        let restored = try ProtectedConfigurationArchive.opened(sealed, passphrase: "correct horse")

        #expect(restored.configuration.servers.first?.name == "工作站")
        #expect(restored.credentials.first?.secret == "hunter2")
    }

    /// The server list is worth protecting too: which servers someone has,
    /// and where, says a good deal even without the passwords.
    @Test("連伺服器清單都看不到明文")
    func revealsNothingWithoutThePassphrase() throws {
        let sealed = try Self.protected().sealed(passphrase: "correct horse")
        let text = String(decoding: sealed, as: UTF8.self)

        #expect(!text.contains("hunter2"))
        #expect(!text.contains("files.example.com"))
        #expect(!text.contains("工作站"))
    }

    /// The specific error, not merely some error: reporting a mistyped
    /// passphrase as an unreadable file sends the user looking for a damaged
    /// backup instead of retyping. An `any Error` expectation here passed
    /// while it did exactly that.
    @Test("密碼錯誤時說的是密碼錯誤")
    func refusesTheWrongPassphraseAndSaysWhy() throws {
        let sealed = try Self.protected().sealed(passphrase: "correct horse")
        #expect(throws: EncryptedArchive.ArchiveError.wrongPassphraseOrDamaged) {
            try ProtectedConfigurationArchive.opened(sealed, passphrase: "wrong")
        }
    }

    @Test("不是備份檔時說的是不認得這個檔案")
    func refusesSomethingElseEntirely() throws {
        #expect(throws: ConfigurationArchive.ArchiveError.unreadable) {
            try ProtectedConfigurationArchive.opened(Data("not a backup".utf8), passphrase: "p")
        }
    }

    @Test("認得出加密備份與一般備份的差別")
    func tellsTheTwoKindsApart() throws {
        let sealed = try Self.protected().sealed(passphrase: "correct horse")
        let plain = try Self.archive(servers: [Self.server("工作站")]).encoded()

        #expect(ProtectedConfigurationArchive.isProtected(sealed))
        #expect(!ProtectedConfigurationArchive.isProtected(plain))
    }

    /// Restored servers take fresh identifiers, so the credentials have to
    /// follow them rather than the ones the archive was written with.
    @Test("憑證跟著還原後的新識別碼走")
    func renamesCredentialsToTheRestoredServers() throws {
        let protectedArchive = Self.protected()
        let plan = protectedArchive.configuration.mergePlan(
            against: [], existingHosts: KnownHosts()
        )
        let restoredID = try #require(plan.servers.first?.id)
        #expect(restoredID != Self.serverID)

        let credentials = protectedArchive.credentials(remappedBy: plan.identifierRemapping)
        #expect(credentials.count == 1)
        #expect(credentials.first?.serverID == restoredID)
        #expect(credentials.first?.secret == "hunter2")
    }

    /// A server the restore skipped is already configured and already has a
    /// password that works; replacing it would be a surprising thing for a
    /// restore to do.
    @Test("被略過的伺服器，其憑證不會覆寫既有的")
    func dropsCredentialsForServersItSkipped() throws {
        let protectedArchive = Self.protected()
        let plan = protectedArchive.configuration.mergePlan(
            against: [Self.server("同一台，名字不同")],
            existingHosts: KnownHosts()
        )

        #expect(plan.duplicateCount == 1)
        #expect(protectedArchive.credentials(remappedBy: plan.identifierRemapping).isEmpty)
    }
}
