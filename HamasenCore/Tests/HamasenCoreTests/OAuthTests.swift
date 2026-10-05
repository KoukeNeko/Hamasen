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

import CryptoKit
import Foundation
import Testing
@testable import HamasenCore

@Suite("OAuth")
struct OAuthTests {
    private static func request(_ provider: OAuthProvider = .google) -> OAuthAuthorizationRequest {
        OAuthAuthorizationRequest(
            provider: provider,
            client: OAuthClient(clientID: " client-id \n", clientSecret: "secret"),
            redirectURI: provider.redirectURI(port: 53682))
    }

    @Test("授權網址帶有 PKCE、state 與各家需要的參數")
    func buildsTheAuthorizationURL() throws {
        let request = Self.request()
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        #expect(value("client_id") == "client-id")
        #expect(value("response_type") == "code")
        #expect(value("redirect_uri") == "http://127.0.0.1:53682/")
        #expect(value("code_challenge_method") == "S256")
        #expect(value("state") == request.state)
        #expect(value("access_type") == "offline")
        let expected = OAuthAuthorizationRequest.base64URL(Data(SHA256.hash(data: Data(request.codeVerifier.utf8))))
        #expect(value("code_challenge") == expected)
        #expect(!request.codeVerifier.contains("="))
    }

    @Test("Microsoft 用 localhost，Dropbox 固定使用同一個連接埠")
    func usesEachProvidersRedirect() {
        #expect(OAuthProvider.microsoft.redirectURI(port: 50000) == "http://localhost:50000/")
        #expect(OAuthProvider.dropbox.requiresPreferredLoopbackPort)
        #expect(!OAuthProvider.google.requiresPreferredLoopbackPort)
    }

    @Test("回呼的 state 不符時拒絕，使用者拒絕時視為取消")
    func validatesTheRedirect() throws {
        let request = Self.request()
        let good = URL(string: "http://127.0.0.1:53682/?code=abc&state=\(request.state)")!
        #expect(try request.authorizationCode(fromRedirect: good) == "abc")

        let forged = URL(string: "http://127.0.0.1:53682/?code=abc&state=other")!
        #expect(throws: OAuthError.stateMismatch) { try request.authorizationCode(fromRedirect: forged) }

        let denied = URL(string: "http://127.0.0.1:53682/?error=access_denied&state=\(request.state)")!
        #expect(throws: OAuthError.cancelled) { try request.authorizationCode(fromRedirect: denied) }
    }

    @Test("表單編碼會跳脫 + 與 &")
    func encodesForms() {
        let encoded = OAuthTokenEndpoint.formEncoded(["code": "a+b&c=d", "grant_type": "authorization_code"])
        #expect(encoded == "code=a%2Bb%26c%3Dd&grant_type=authorization_code")
    }

    @Test("交換授權碼取得權杖，更新時保留未輪替的 refresh token")
    func exchangesAndRefreshes() async throws {
        let session = StubURLProtocol.session { request in
            let form = String(decoding: request.body, as: UTF8.self)
            if form.contains("grant_type=authorization_code") {
                guard form.contains("code_verifier="), form.contains("client_secret=secret") else { return .status(400) }
                return .json(["access_token": "first", "refresh_token": "refresh-token", "expires_in": 3600])
            }
            return .json(["access_token": "second", "expires_in": 3600])
        }
        let request = Self.request()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let token = try await OAuthTokenEndpoint.exchange(code: "code", for: request, using: session, now: now)
        #expect(token.accessToken == "first")
        #expect(token.expiresAt == now.addingTimeInterval(3600))
        #expect(token.client.clientID == "client-id")

        let renewed = try await OAuthTokenEndpoint.refresh(token, using: session)
        #expect(renewed.accessToken == "second")
        #expect(renewed.refreshToken == "refresh-token")
    }

    @Test("refresh token 失效時回報需要重新登入")
    func reportsARevokedRefreshToken() async throws {
        let session = StubURLProtocol.session { _ in .json(["error": "invalid_grant"], status: 400) }
        await #expect(throws: RemoteFileServiceError.authenticationFailed) {
            _ = try await OAuthTokenEndpoint.refresh(CloudFixtures.token(provider: .dropbox), using: session)
        }
    }

    @Test("同時要求更新只會送出一次")
    func renewsOnceForConcurrentCallers() async throws {
        let issuer = StubTokenIssuer()
        let session = StubURLProtocol.session { request in issuer.handle(request) }
        let auth = OAuthSession(
            token: CloudFixtures.token(provider: .google, access: "old", expiresIn: -60),
            serverID: nil, store: CloudFixtures.keychain, urlSession: session)
        async let first = auth.accessToken()
        async let second = auth.accessToken()
        let tokens = try await [first, second]
        #expect(tokens == ["access-1", "access-1"])
        #expect(issuer.refreshCount == 1)
    }

    @Test("權杖可以在鑰匙圈格式之間來回轉換")
    func roundTripsTokens() throws {
        let token = CloudFixtures.token(provider: .microsoft)
        let decoded = try OAuthToken.decoded(from: try token.encoded())
        #expect(decoded.provider == .microsoft)
        #expect(decoded.refreshToken == "refresh-token")
        #expect(abs((decoded.expiresAt ?? .distantPast).timeIntervalSince(token.expiresAt!)) < 1)
    }
}
