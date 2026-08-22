import Foundation
import Testing
@testable import HamasenCore

@Suite("CyberduckBookmark")
struct CyberduckBookmarkTests {
    /// Builds a property list the way Cyberduck writes one, so the fixtures
    /// read like the files they stand for.
    private static func file(
        named name: String = "bookmark.duck",
        _ entries: [String: String]
    ) -> CyberduckBookmarkFile {
        let body = entries
            .sorted { $0.key < $1.key }
            .map { "\t<key>\($0.key)</key>\n\t<string>\($0.value)</string>" }
            .joined(separator: "\n")
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \(body)
        </dict>
        </plist>
        """
        return CyberduckBookmarkFile(name: name, contents: Data(plist.utf8))
    }

    private static func sftpBookmark(
        named name: String = "bookmark.duck",
        extraEntries: [String: String] = [:]
    ) -> CyberduckBookmarkFile {
        file(named: name, [
            "Protocol": "sftp",
            "Nickname": "工作站",
            "Hostname": "files.example.com",
            "Port": "2222",
            "Username": "doeshing",
            "Path": "/srv/data",
        ].merging(extraEntries) { _, override in override })
    }

    @Test("SFTP 書籤的每個欄位都帶進來")
    func readsAnSFTPBookmark() {
        let summary = CyberduckBookmark.read([Self.sftpBookmark()])

        #expect(summary.servers.count == 1)
        let config = summary.servers.first?.config
        #expect(config?.name == "工作站")
        #expect(config?.transferProtocol == .sftp)
        #expect(config?.host == "files.example.com")
        #expect(config?.port == 2222)
        #expect(config?.username == "doeshing")
        #expect(config?.remotePath == "/srv/data")
        #expect(config?.authenticationMethod == .password)
        #expect(summary.servers.first?.unresolvedRemotePath == nil)
    }

    @Test("WebDAV 的兩種協定各自對應")
    func mapsWebDAVProtocols() {
        let summary = CyberduckBookmark.read([
            Self.file(["Protocol": "dav", "Hostname": "a.example.com"]),
            Self.file(["Protocol": "davs", "Hostname": "b.example.com"]),
        ])

        #expect(summary.servers.map(\.config.transferProtocol) == [.webdav, .webdavs])
    }

    @Test("指定金鑰的書籤改用金鑰驗證")
    func usesKeyAuthenticationWhenTheBookmarkNamesAKey() {
        let summary = CyberduckBookmark.read([
            Self.sftpBookmark(extraEntries: ["Private Key File": "~/.ssh/id_ed25519"])
        ])

        #expect(summary.servers.first?.config.authenticationMethod == .privateKey)
    }

    /// Cyberduck resolves this against the login directory; the import
    /// cannot, so it says so instead of mounting the wrong place.
    @Test("相對路徑改掛根目錄，並回報原本的路徑")
    func fallsBackToTheRootForARelativePath() {
        let summary = CyberduckBookmark.read([
            Self.sftpBookmark(extraEntries: ["Path": "~/Documents"])
        ])

        #expect(summary.servers.first?.config.remotePath == "/")
        #expect(summary.servers.first?.unresolvedRemotePath == "~/Documents")
    }

    @Test("尚未支援的協定會被列出而不是匯入")
    func namesUnsupportedProtocols() {
        let summary = CyberduckBookmark.read([
            Self.file(["Protocol": "s3", "Hostname": "s3.amazonaws.com"]),
            Self.file(["Protocol": "googledrive", "Hostname": "drive.google.com"]),
            Self.file(["Protocol": "s3", "Hostname": "other.example.com"]),
        ])

        #expect(summary.servers.isEmpty)
        #expect(summary.unsupportedProtocols == ["s3", "googledrive"])
    }

    @Test("FTP 與 FTPS 書籤也匯入")
    func mapsFTPProtocols() {
        let summary = CyberduckBookmark.read([
            Self.file(["Protocol": "ftp", "Hostname": "a.example.com"]),
            Self.file(["Protocol": "ftps", "Hostname": "b.example.com"]),
        ])

        #expect(summary.servers.map(\.config.transferProtocol) == [.ftp, .ftps])
    }

    @Test("已經在清單中的連線會被略過")
    func skipsServersAlreadyConfigured() {
        let existing = ServerConfig(
            name: "另一個名字",
            transferProtocol: .sftp,
            host: "FILES.example.com",
            port: 2222,
            username: "doeshing",
            remotePath: "/srv/data"
        )
        let summary = CyberduckBookmark.read(
            [Self.sftpBookmark()],
            skippingDuplicatesOf: [existing]
        )

        #expect(summary.servers.isEmpty)
        #expect(summary.duplicateCount == 1)
    }

    @Test("同一批裡重複的書籤只匯入一次")
    func skipsDuplicatesWithinOneImport() {
        let summary = CyberduckBookmark.read([Self.sftpBookmark(), Self.sftpBookmark()])

        #expect(summary.servers.count == 1)
        #expect(summary.duplicateCount == 1)
    }

    @Test("不是屬性列表或沒有主機的檔案算無法辨識")
    func countsFilesThatDescribeNoServer() {
        let summary = CyberduckBookmark.read([
            CyberduckBookmarkFile(name: "notes.txt", contents: Data("not a plist".utf8)),
            Self.file(["Protocol": "sftp"]),
            Self.file(["Hostname": "files.example.com"]),
        ])

        #expect(summary.servers.isEmpty)
        #expect(summary.unusableCount == 3)
    }

    @Test("連線設定檔用它自己的預設值")
    func readsAConnectionProfile() {
        let profile = Self.file(named: "Nextcloud.cyberduckprofile", [
            "Protocol": "davs",
            "Description": "Nextcloud",
            "Default Hostname": "cloud.example.com",
            "Default Path": "/remote.php/webdav",
        ])
        let summary = CyberduckBookmark.read([profile])

        let config = summary.servers.first?.config
        #expect(config?.name == "Nextcloud")
        #expect(config?.host == "cloud.example.com")
        #expect(config?.remotePath == "/remote.php/webdav")
        #expect(config?.username.isEmpty == true)
    }

    /// A bookmark writes the port as a string, a profile as a number.
    @Test("數字型態的埠號也讀得到")
    func readsANumericPort() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
        \t<key>Protocol</key><string>davs</string>
        \t<key>Default Hostname</key><string>cloud.example.com</string>
        \t<key>Default Port</key><integer>8443</integer>
        </dict>
        </plist>
        """
        let summary = CyberduckBookmark.read([
            CyberduckBookmarkFile(name: "p.cyberduckprofile", contents: Data(plist.utf8))
        ])

        #expect(summary.servers.first?.config.port == 8443)
    }

    @Test("埠號超出範圍時退回協定預設值")
    func fallsBackToTheProtocolPortWhenTheStoredOneIsUnusable() {
        let summary = CyberduckBookmark.read([
            Self.sftpBookmark(extraEntries: ["Port": "99999"])
        ])

        #expect(summary.servers.first?.config.port == ServerConfig.defaultSFTPPort)
    }

    @Test("沒有暱稱時用檔名當名稱")
    func namesTheServerAfterTheFileWithoutANickname() {
        let summary = CyberduckBookmark.read([
            Self.file(named: "files.example.com – SFTP.duck", [
                "Protocol": "sftp",
                "Hostname": "files.example.com",
                "Username": "doeshing",
            ])
        ])

        #expect(summary.servers.first?.config.name == "files.example.com – SFTP")
    }

    @Test("空白欄位不算值")
    func treatsBlankFieldsAsAbsent() {
        let summary = CyberduckBookmark.read([
            Self.file(named: "fallback.duck", [
                "Protocol": "sftp",
                "Nickname": "  ",
                "Hostname": "files.example.com",
                "Path": "  ",
            ])
        ])

        #expect(summary.servers.first?.config.name == "fallback")
        #expect(summary.servers.first?.config.remotePath == "/")
    }
}
