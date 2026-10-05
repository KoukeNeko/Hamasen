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

/// What changes on the other side over the years a connection is kept: the
/// password, the server's key and certificate, the sign-in. Each must be
/// reported as what it is, so the person is asked for the right thing, and
/// each must be recoverable without removing the connection.
///
/// One at a time, and each puts the server back as it found it: these
/// change what every other test signs in with.
@Suite("Credentials and identity over time", .enabled(if: E2E.isAvailable), .serialized)
struct IdentityTests {
    @Test("伺服器密碼變更後回報認證失敗，更新密碼後恢復", arguments: Lane.allCases.filter(\.hasPassword))
    func followsPasswordChange(lane: Lane) async throws {
        let clients = LaneClients(lane: lane, viaProxy: false)
        _ = try await clients.connected()
        let newPassword = "rotated-\(UUID().uuidString.prefix(6))"
        try await ServerControl.exec(lane.service, "set-password", newPassword)
        do {
            await #expect(throws: RemoteFileServiceError.authenticationFailed, "\(lane) with the old password") {
                _ = try await clients.connected()
            }
            clients.credentials.currentPassword = newPassword
            let service = try await clients.connected()
            _ = try await service.listDirectory(at: RemotePath.root)
        } catch {
            try await ServerControl.exec(lane.service, "set-password", E2E.password)
            throw error
        }
        try await ServerControl.exec(lane.service, "set-password", E2E.password)
    }

    /// A rebuilt server and an impostor look the same from here, so a new
    /// key is refused until the person clears the old one.
    @Test("SSH 主機金鑰更換後拒絕連線，清除紀錄後重新信任")
    func refusesChangedHostKey() async throws {
        let clients = LaneClients(lane: .sftp, viaProxy: false)
        _ = try await clients.connected()
        try await ServerControl.exec("sftp", "rotate-hostkey")

        do {
            _ = try await clients.connected()
            Issue.record("connected to a server whose key changed")
        } catch RemoteFileServiceError.hostKeyChanged {
        }

        let store = KnownHostsStore(fileURL: clients.credentials.knownHostsURL)
        try store.forget(endpoint: KnownHosts.endpoint(host: clients.config.host, port: clients.config.port))
        let service = try await clients.connected()
        _ = try await service.listDirectory(at: RemotePath.root)
        // And the new key is the one kept: the next connection is not a
        // first use again.
        #expect(try store.load().fingerprint(forEndpoint: KnownHosts.endpoint(
            host: clients.config.host, port: clients.config.port)) != nil)
    }

    /// Certificates are reissued every year or so; one from the same
    /// authority is no reason to stop working.
    @Test("TLS 憑證更新後照常連線", arguments: [Lane.ftps, .webdavs])
    func acceptsReissuedCertificate(lane: Lane) async throws {
        let mount = Mount(LaneClients(lane: lane, viaProxy: false))
        _ = try await mount.read { try await $0.listDirectory(at: RemotePath.root) }
        try await ServerControl.exec(lane.service, "rotate-cert")
        _ = try await E2E.withDeadline(60, "\(lane) after the certificate changed") {
            try await mount.read { try await $0.listDirectory(at: RemotePath.root) }
        }
        let fresh = try await LaneClients(lane: lane, viaProxy: false).connected()
        _ = try await fresh.listDirectory(at: RemotePath.root)
    }

    /// Revoked access — a changed account password, or the app removed in the
    /// provider's settings — reads as a sign-in to redo, not a server down.
    @Test("雲端授權被撤銷後回報需要重新登入，登入後恢復", arguments: [Lane.dropbox, .oneDrive, .googleDrive])
    func asksToSignInAgainAfterRevocation(lane: Lane) async throws {
        let mount = Mount(LaneClients(lane: lane, viaProxy: false))
        _ = try await mount.read { try await $0.listDirectory(at: RemotePath.root) }
        try await CloudMock.revoke(lane.oauthProvider!)

        await #expect(throws: RemoteFileServiceError.authenticationFailed, "\(lane) after revocation") {
            _ = try await mount.read { try await $0.listDirectory(at: RemotePath.root) }
        }
        try await mount.clients.signIn()
        await mount.discard()
        _ = try await mount.read { try await $0.listDirectory(at: RemotePath.root) }
    }

    /// The app and the extension each hold a session for the same
    /// connection. When the token expires, one renews and the other takes
    /// its result: renewing twice spends a Microsoft refresh token that,
    /// once rotated, works for only a minute more.
    @Test("兩個行程共用的權杖只更新一次", arguments: [Lane.dropbox, .oneDrive, .googleDrive])
    func renewsSharedTokenOnce(lane: Lane) async throws {
        let clients = LaneClients(lane: lane, viaProxy: false)
        var expired = try await clients.signIn()
        expired.expiresAt = Date().addingTimeInterval(-60)
        try clients.credentials.saveOAuthToken(expired, for: clients.id)

        let app = try await clients.make()
        let fileProvider = try await clients.make()
        let before = try await CloudMock.refreshCount(lane.oauthProvider!)
        _ = try await app.listDirectory(at: RemotePath.root)
        _ = try await fileProvider.listDirectory(at: RemotePath.root)
        let after = try await CloudMock.refreshCount(lane.oauthProvider!)
        #expect(after - before == 1, "\(lane) renewed \(after - before) times")

        let renewed = try clients.credentials.loadOAuthToken(for: clients.id)
        #expect(renewed.accessToken != expired.accessToken)
        #expect(!renewed.needsRefresh())
    }
}
