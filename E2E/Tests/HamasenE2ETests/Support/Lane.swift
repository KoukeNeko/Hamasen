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
import Testing
@testable import HamasenCore

/// One kind of server a user can connect to, as the e2e stack provides it.
enum Lane: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case sftp
    case ftp
    case ftps
    case webdav
    case webdavs
    case smb
    case s3
    case dropbox
    case oneDrive
    case googleDrive

    var testDescription: String { rawValue }

    /// The compose service behind the lane, for restarts and /e2e commands.
    var service: String {
        switch self {
        case .sftp: return "sftp"
        case .ftp, .ftps: return "ftp"
        case .webdav: return "webdav"
        case .webdavs: return "webdavs"
        case .smb: return "smb"
        case .s3: return "s3"
        case .dropbox, .oneDrive, .googleDrive: return "cloud"
        }
    }

    /// The toxiproxy proxy in front of the lane, if there is one.
    var proxy: String? {
        switch self {
        case .sftp: return "sftp"
        case .ftp, .ftps: return "ftp"
        case .webdav: return "webdav"
        case .webdavs: return nil
        case .smb: return "smb"
        case .s3: return "s3"
        case .dropbox, .oneDrive, .googleDrive: return "cloud"
        }
    }

    /// What keeps an upload through the lane's proxy going long enough to be
    /// cut partway. FTP's data connections bypass the proxy and finish in
    /// moments, so its replies are held back instead, and the cut lands
    /// between the data arriving and the rename that would put it in place.
    var uploadSlowing: [(toxic: Toxiproxy.Toxic, stream: String)] {
        switch self {
        case .ftp, .ftps: return [(.latency(milliseconds: 1_000), "downstream")]
        default: return [(.bandwidth(kilobytesPerSecond: 400), "upstream")]
        }
    }

    var oauthProvider: OAuthProvider? {
        switch self {
        case .dropbox: return .dropbox
        case .oneDrive: return .microsoft
        case .googleDrive: return .google
        default: return nil
        }
    }

    /// Whether the server's password can be changed with /e2e set-password.
    var hasPassword: Bool {
        switch self {
        case .sftp, .ftp, .ftps, .webdav, .webdavs, .smb: return true
        case .s3, .dropbox, .oneDrive, .googleDrive: return false
        }
    }

    /// Whether a modification time set on the server with /e2e touch reads
    /// back, and to what precision.
    var modificationTimePrecision: TimeInterval? {
        switch self {
        case .sftp, .smb, .webdav, .webdavs: return 1
        // vsftpd lists without MLSD: minutes for the last six months, days
        // before that.
        case .ftp, .ftps: return 86_400
        case .s3, .dropbox, .oneDrive, .googleDrive: return nil
        }
    }
}

/// What a lane's client signs in with, kept the way the app keeps it: one
/// record per connection that every client made for it reads, and that a
/// client renewing its token writes back — the Keychain's role in the app.
final class LaneCredentials: OAuthTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var password: String
    private var tokens: [UUID: OAuthToken] = [:]
    let knownHostsURL: URL

    init(lane: Lane) {
        password = lane == .s3 ? E2E.s3Secret : E2E.password
        knownHostsURL = E2E.runDirectory.appending(path: "known-hosts-\(UUID().uuidString.prefix(8)).json")
    }

    var currentPassword: String {
        get { lock.withLock { password } }
        set { lock.withLock { password = newValue } }
    }

    func loadOAuthToken(for serverID: UUID) throws -> OAuthToken {
        guard let token = lock.withLock({ tokens[serverID] }) else {
            throw KeychainCredentialStore.KeychainError.itemNotFound
        }
        return token
    }

    func saveOAuthToken(_ token: OAuthToken, for serverID: UUID) throws {
        lock.withLock { tokens[serverID] = token }
    }

    /// Forgets the sign-in, as signing out does.
    func signOut(_ serverID: UUID) {
        lock.withLock { tokens[serverID] = nil }
    }
}

/// Builds clients for a lane, the way the extension builds them for a
/// configured server — through the same types, with only what differs in
/// the test environment injected: the test CA, the cloud mock's address, a
/// known-hosts file of its own.
struct LaneClients: Sendable {
    let lane: Lane
    /// The connection's identity, which its token is filed under.
    let id = UUID()
    let credentials: LaneCredentials
    /// Through toxiproxy, where the lane has a proxy, so faults can be
    /// injected; directly otherwise.
    let viaProxy: Bool
    let connectTimeoutSeconds: Int

    init(lane: Lane, viaProxy: Bool = true, connectTimeoutSeconds: Int = 10) {
        self.lane = lane
        self.credentials = LaneCredentials(lane: lane)
        self.viaProxy = viaProxy && lane.proxy != nil
        self.connectTimeoutSeconds = connectTimeoutSeconds
    }

    var config: ServerConfig {
        func make(_ transferProtocol: ServerConfig.TransferProtocol, host: String = E2E.host,
                  port: Int, username: String = E2E.username, remotePath: String,
                  authentication: ServerConfig.AuthenticationMethod = .password) -> ServerConfig {
            ServerConfig(
                id: id, name: "e2e \(lane.rawValue)", transferProtocol: transferProtocol, host: host, port: port,
                username: username, authenticationMethod: authentication, remotePath: remotePath)
        }
        switch lane {
        case .sftp:
            return make(.sftp, port: viaProxy ? E2E.Port.sftpProxied : E2E.Port.sftp, remotePath: "/home/hamasen/data")
        case .ftp:
            return make(.ftp, port: viaProxy ? E2E.Port.ftpProxied : E2E.Port.ftp, remotePath: "/data")
        case .ftps:
            return make(.ftps, host: E2E.tlsHost, port: viaProxy ? E2E.Port.ftpProxied : E2E.Port.ftp, remotePath: "/data")
        case .webdav:
            return make(.webdav, port: viaProxy ? E2E.Port.webdavProxied : E2E.Port.webdav, remotePath: "/")
        case .webdavs:
            return make(.webdavs, host: E2E.tlsHost, port: E2E.Port.webdavs, remotePath: "/")
        case .smb:
            return make(.smb, port: viaProxy ? E2E.Port.smbProxied : E2E.Port.smb, remotePath: "/data")
        case .s3:
            return make(.s3, port: viaProxy ? E2E.Port.s3Proxied : E2E.Port.s3, username: E2E.s3AccessKey,
                        remotePath: "/\(E2E.s3Bucket)")
        case .dropbox, .oneDrive, .googleDrive:
            let transferProtocol: ServerConfig.TransferProtocol =
                lane == .dropbox ? .dropbox : lane == .oneDrive ? .oneDrive : .googleDrive
            return make(transferProtocol, host: lane.oauthProvider!.apiHost, port: 443, username: "",
                        remotePath: "/", authentication: .oauth)
        }
    }

    var cloudPort: Int { viaProxy ? E2E.Port.cloudProxied : E2E.Port.cloud }

    /// A new client, not yet connected.
    func make() async throws -> any RemoteFileService {
        let config = config
        switch lane {
        case .sftp:
            return SFTPFileService(
                config: config, credentials: .password(credentials.currentPassword),
                connectTimeoutSeconds: connectTimeoutSeconds,
                hostKeyPolicy: .trustOnFirstUse(KnownHostsStore(fileURL: credentials.knownHostsURL)))
        case .ftp:
            return FTPFileService(
                config: config, credentials: .password(credentials.currentPassword),
                connectTimeoutSeconds: connectTimeoutSeconds)
        case .ftps:
            return FTPFileService(
                config: config, credentials: .password(credentials.currentPassword),
                connectTimeoutSeconds: connectTimeoutSeconds, tlsTrustRoots: try E2E.caForNIO())
        case .webdav:
            return WebDAVFileService(
                config: config, credentials: .password(credentials.currentPassword),
                connectTimeoutSeconds: connectTimeoutSeconds)
        case .webdavs:
            return WebDAVFileService(
                config: config, credentials: .password(credentials.currentPassword),
                connectTimeoutSeconds: connectTimeoutSeconds, trustedAnchors: [try E2E.caForSecurity()])
        case .smb:
            return SMBFileService(
                config: config, credentials: .password(credentials.currentPassword),
                connectTimeoutSeconds: connectTimeoutSeconds)
        case .s3:
            // Small parts, so multipart uploads happen at sizes a test can
            // afford to send many of.
            return S3FileService(
                config: config, credentials: .password(credentials.currentPassword),
                endpoint: S3Endpoint(scheme: "http", host: config.host, port: config.port,
                                     region: E2E.s3Region, addressingStyle: .path),
                connectTimeoutSeconds: connectTimeoutSeconds,
                multipartThresholdBytes: 6 * 1024 * 1024, partSizeBytes: 5 * 1024 * 1024)
        case .dropbox, .oneDrive, .googleDrive:
            let token: OAuthToken
            if let stored = try? credentials.loadOAuthToken(for: id) {
                token = stored
            } else {
                token = try await signIn()
            }
            let session = CloudMock.session(port: cloudPort)
            switch lane {
            case .dropbox:
                return try DropboxFileService(config: config, credentials: .oauth(token), urlSession: session,
                                              keychain: credentials)
            case .oneDrive:
                return try OneDriveFileService(config: config, credentials: .oauth(token), urlSession: session,
                                               keychain: credentials)
            default:
                return try GoogleDriveFileService(config: config, credentials: .oauth(token), urlSession: session,
                                                  keychain: credentials)
            }
        }
    }

    /// A connected client.
    func connected() async throws -> any RemoteFileService {
        let service = try await make()
        try await service.connect()
        return service
    }

    /// Signs in to the lane's cloud drive again, as the person would after
    /// being told the sign-in expired, and keeps the new token.
    @discardableResult
    func signIn() async throws -> OAuthToken {
        let token = try await CloudMock.signIn(lane.oauthProvider!)
        try credentials.saveOAuthToken(token, for: id)
        return token
    }
}
