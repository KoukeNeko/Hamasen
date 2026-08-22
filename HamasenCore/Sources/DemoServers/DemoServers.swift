import Foundation
import HamasenTestServers

/// Runs an SFTP and an FTP server on this Mac, serving a directory of
/// made-up files.
///
/// It exists so the app can be shown — a screenshot, a walkthrough — without
/// pointing it at a real server, whose hostname and account would be in every
/// picture. The servers are the ones the test suite already runs the client
/// against, so this shows nothing the tests do not also cover.
///
/// The account is the one the tests use, printed on start, and everything
/// here vanishes when this process ends.
@main
struct DemoServers {
    private static let sftpPort = 2222
    private static let ftpPort = 2121

    /// Names for the demo servers, under the TLD RFC 2606 reserves for
    /// exactly this. `.test` can never be registered, so these can never
    /// start resolving to somebody else's machine.
    ///
    /// They have to be reached through /etc/hosts rather than through DNS: a
    /// public name pointing at 127.0.0.1 is what DNS rebinding protection
    /// exists to discard, and both home routers and VPN resolvers do discard
    /// it. /etc/hosts is not consulted over the network and is not filtered.
    private static let sftpHostname = "files.hamasen.test"
    private static let ftpHostname = "ftp.hamasen.test"

    static func main() async throws {
        let sftp = try await TestSFTPServer.start(preferredPort: sftpPort)
        let ftp = try await TestFTPServer.start(preferredPort: ftpPort)

        try DemoContent.populate(sftp.rootDirectory)
        try DemoContent.populate(ftp.rootDirectory)

        print(
            """

            Two demo servers are running. Both accept the same account.

              SFTP   127.0.0.1:\(sftp.port)
              FTP    127.0.0.1:\(ftp.port)
              user   \(TestSFTPServer.username)
              pass   \(TestSFTPServer.password)

            For a picture without an address in it, name them once:

              printf '\\n# Hamasen demo servers\\n127.0.0.1\\t\(sftpHostname)\\n127.0.0.1\\t\(ftpHostname)\\n' | sudo tee -a /etc/hosts

            then connect to \(sftpHostname):\(sftp.port) and \(ftpHostname):\(ftp.port).
            To undo it:

              sudo sed -i '' '/hamasen.test/d;/# Hamasen demo servers/d' /etc/hosts

            Add either in Hamasen, give it whatever display name suits the
            picture, and mount it. Nothing here outlives this process.

            Press Ctrl-C to stop.

            """
        )

        // Printed output to a pipe is buffered, so a caller reading this
        // from anywhere but a terminal would see nothing until the process
        // ended — which is never, by design.
        fflush(stdout)

        // Nothing else to do: the servers run on their own event loops until
        // this process is interrupted.
        while !Task.isCancelled {
            try await Task.sleep(for: .seconds(3600))
        }
        try await sftp.stop()
        try await ftp.stop()
    }
}

/// Files with plausible names and sizes, so a screenshot of the app looks
/// like somebody's work rather than an empty folder.
enum DemoContent {
    private static let tree: [String: [(name: String, kilobytes: Int)]] = [
        "Designs": [
            ("app-icon.sketch", 2_400),
            ("onboarding-flow.pdf", 860),
            ("palette.png", 120),
        ],
        "Releases": [
            ("release-notes.md", 6),
            ("checksums.txt", 2),
        ],
        "Site": [
            ("index.html", 14),
            ("styles.css", 22),
            ("analytics.json", 48),
        ],
        "Backups": [
            ("2026-08-01.tar.gz", 18_500),
            ("2026-07-01.tar.gz", 17_900),
        ],
    ]

    private static let looseFiles: [(name: String, kilobytes: Int)] = [
        ("README.md", 4),
        ("deploy.sh", 2),
    ]

    static func populate(_ root: URL) throws {
        for (directory, files) in tree {
            let url = root.appendingPathComponent(directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for file in files {
                try write(file, into: url)
            }
        }
        for file in looseFiles {
            try write(file, into: root)
        }
    }

    /// Filled with repeated text rather than zeroes, so anything that opens
    /// one sees a file rather than a blank of the right length.
    private static func write(_ file: (name: String, kilobytes: Int), into directory: URL) throws {
        let line = "Demo content for \(file.name). Not a real file.\n"
        var contents = ""
        while contents.utf8.count < file.kilobytes * 1024 {
            contents += line
        }
        try Data(contents.utf8).write(to: directory.appendingPathComponent(file.name))
    }
}
