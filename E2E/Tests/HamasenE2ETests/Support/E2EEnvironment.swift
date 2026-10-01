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
import NIOSSL
import Security

/// The Docker environment E2E/CONTRACT.md describes, as constants.
enum E2E {
    /// Set by scripts/e2e.sh once the stack is healthy. Without it every
    /// suite here is skipped, so a plain `swift test` never waits on ports
    /// nobody is listening on.
    static var isAvailable: Bool {
        ProcessInfo.processInfo.environment["HAMASEN_E2E"] == "1"
    }

    /// The E2E directory: this file is at E2E/Tests/HamasenE2ETests/Support.
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    /// Where the harness finds the CA and the SFTP key, and writes what it
    /// keeps: E2E/.run for a stack on this Mac; set by scripts/e2e.sh to a
    /// copy of the remote one when the stack runs on another host.
    static let runDirectory = ProcessInfo.processInfo.environment["HAMASEN_E2E_RUN_DIR"]
        .map { URL(fileURLWithPath: $0) } ?? directory.appending(path: ".run")

    /// The machine the services run on. This Mac by default; another one
    /// when scripts/e2e.sh was told to start them there over SSH, so the
    /// clients cross a real network.
    static let host = ProcessInfo.processInfo.environment["HAMASEN_E2E_HOST"] ?? "127.0.0.1"

    static var isRemote: Bool { host != "127.0.0.1" }

    /// The name TLS clients connect to, which the server certificate has to
    /// carry: localhost on this Mac, the host's own address otherwise.
    static var tlsHost: String { isRemote ? host : "localhost" }

    static let username = "hamasen"
    static let password = "hamasen-e2e"
    static let s3AccessKey = "hamasen-e2e"
    static let s3Secret = "hamasen-e2e-secret"
    static let s3Bucket = "hamasen"
    static let s3Region = "us-east-1"

    enum Port {
        static let sftp = 2222, sftpProxied = 12222
        static let ftp = 2121, ftpProxied = 12121
        static let webdav = 8081, webdavProxied = 18081
        static let webdavs = 8443
        static let smb = 1445, smbProxied = 11445
        static let s3 = 8333, s3Proxied = 18333
        static let cloud = 8090, cloudProxied = 18090
        static let toxiproxy = 8474
    }

    /// The private key authorized for `hamasen` on the SFTP server.
    static func sshPrivateKey() throws -> String {
        try String(contentsOf: runDirectory.appending(path: "keys/id_ed25519"), encoding: .utf8)
    }

    static func caPEM() throws -> String {
        try String(contentsOf: runDirectory.appending(path: "certs/ca.pem"), encoding: .utf8)
    }

    /// The test certificate authority, as FTPS's TLS stack wants it.
    static func caForNIO() throws -> NIOSSLTrustRoots {
        .certificates(try NIOSSLCertificate.fromPEMBytes(Array(try caPEM().utf8)))
    }

    /// The test certificate authority, as URLSession's trust evaluation
    /// wants it.
    static func caForSecurity() throws -> SecCertificate {
        let base64 = try caPEM()
            .split(separator: "\n")
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let der = Data(base64Encoded: base64),
              let certificate = SecCertificateCreateWithData(nil, der as CFData)
        else { throw E2EError.unreadable("ca.pem") }
        return certificate
    }

    /// A name no other run uses, for the folder each run works in.
    static func uniqueName(_ prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString.prefix(8).lowercased())"
    }
}

enum E2EError: Error, CustomStringConvertible {
    case unreadable(String)
    case command(String, Int32, String)
    case unexpected(String)

    var description: String {
        switch self {
        case .unreadable(let what): return "cannot read \(what)"
        case .command(let command, let status, let output): return "\(command) exited \(status): \(output)"
        case .unexpected(let what): return what
        }
    }
}
