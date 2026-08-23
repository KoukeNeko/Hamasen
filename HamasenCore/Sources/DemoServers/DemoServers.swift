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
import HamasenTestServers

/// Runs an SFTP, an FTP and an S3 server on this Mac, serving made-up files.
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
    private static let s3Port = 9000

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
    /// Not named through /etc/hosts like the other two: the app speaks plain
    /// HTTP to a loopback address and HTTPS to anything else, and a name
    /// resolving to 127.0.0.1 is not a loopback address as far as that check
    /// is concerned.
    private static let s3Hostname = "127.0.0.1"

    static func main() async throws {
        let sftp = try await TestSFTPServer.start(preferredPort: sftpPort)
        let ftp = try await TestFTPServer.start(preferredPort: ftpPort)
        let s3 = try await TestS3Server.start(preferredPort: s3Port)

        try DemoContent.populate(sftp.rootDirectory)
        try DemoContent.populate(ftp.rootDirectory)
        DemoContent.populate(s3.store)

        print(
            """

            Three demo servers are running. Nothing here outlives this process.

              SFTP    127.0.0.1:\(sftp.port)
              FTP     127.0.0.1:\(ftp.port)
                      user \(TestSFTPServer.username)   password \(TestSFTPServer.password)
                      Both accept that one account.

              S3      \(s3Hostname):\(s3.port)
                      remote path  /\(TestS3Server.bucket)
                      access key   \(TestS3Server.credentials.accessKeyID)
                      secret key   \(TestS3Server.credentials.secretAccessKey)

            Add one in Hamasen under the matching protocol. Set the port by
            hand: the form fills in the protocol's own default, which none of
            these use. For S3 the remote path is the bucket and is required.

            For a picture with no address in it, name the SFTP and FTP servers
            once:

              printf '\\n# Hamasen demo servers\\n127.0.0.1\\t\(sftpHostname)\\n127.0.0.1\\t\(ftpHostname)\\n' | sudo tee -a /etc/hosts

            then connect to \(sftpHostname):\(sftp.port) and \(ftpHostname):\(ftp.port).
            To undo it:

              sudo sed -i '' '/hamasen.test/d;/# Hamasen demo servers/d' /etc/hosts

            The S3 one stays on \(s3Hostname). The app speaks plain HTTP to a
            loopback address and HTTPS to everything else, and a name pointing
            at 127.0.0.1 is not a loopback address as far as that check goes.

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
        try await s3.stop()
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

    /// The same tree as objects. S3 has no directories, so a folder is the
    /// shared start of other keys — and an empty one would need a marker,
    /// which nothing here has.
    static func populate(_ store: TestS3ObjectStore) {
        for (directory, files) in tree {
            for file in files {
                store.put(body(for: file), forKey: "\(directory)/\(file.name)")
            }
        }
        for file in looseFiles {
            store.put(body(for: file), forKey: file.name)
        }
    }

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
        try body(for: file).write(to: directory.appendingPathComponent(file.name))
    }

    private static func body(for file: (name: String, kilobytes: Int)) -> Data {
        let line = "Demo content for \(file.name). Not a real file.\n"
        var contents = ""
        while contents.utf8.count < file.kilobytes * 1024 {
            contents += line
        }
        return Data(contents.utf8)
    }
}
