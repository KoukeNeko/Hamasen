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

/// What a sign-in leaves behind. Kept in the Keychain as one JSON item per
/// connection, and refreshed there by whichever process notices it expiring.
public struct OAuthToken: Codable, Sendable, Equatable {
    public let provider: OAuthProvider
    public let client: OAuthClient
    public var accessToken: String
    /// Absent only if the provider never issued one, in which case the
    /// connection stops working when the access token expires.
    public var refreshToken: String?
    public var expiresAt: Date?

    public init(
        provider: OAuthProvider,
        client: OAuthClient,
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date?
    ) {
        self.provider = provider
        self.client = client
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// Renewed a little early, so a request is never sent with a token that
    /// expires on the way.
    public func needsRefresh(at date: Date = Date(), leeway: TimeInterval = 120) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.addingTimeInterval(-leeway) <= date
    }

    func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    static func decoded(from text: String) throws -> OAuthToken {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(OAuthToken.self, from: Data(text.utf8))
    }
}

/// The token endpoint, for the two grants a desktop client uses.
public enum OAuthTokenEndpoint {
    /// Trades the code the redirect delivered for the first token.
    public static func exchange(
        code: String,
        for request: OAuthAuthorizationRequest,
        using session: URLSession = .shared,
        now: Date = Date()
    ) async throws -> OAuthToken {
        var fields = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": request.redirectURI,
            "client_id": request.client.clientID,
            "code_verifier": request.codeVerifier,
        ]
        if let secret = request.client.clientSecret { fields["client_secret"] = secret }
        let response = try await post(fields, to: request.provider.tokenURL, using: session)
        return OAuthToken(
            provider: request.provider,
            client: request.client,
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expiresAt: response.expiresIn.map { now.addingTimeInterval($0) }
        )
    }

    /// Gets a new access token. A provider that rotates refresh tokens sends
    /// a new one, which replaces the old; one that does not sends none, and
    /// the old one stays.
    public static func refresh(
        _ token: OAuthToken,
        using session: URLSession = .shared,
        now: Date = Date()
    ) async throws -> OAuthToken {
        guard let refreshToken = token.refreshToken else {
            throw RemoteFileServiceError.authenticationFailed
        }
        var fields = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": token.client.clientID,
        ]
        if let secret = token.client.clientSecret { fields["client_secret"] = secret }
        let response = try await post(fields, to: token.provider.tokenURL, using: session)
        var renewed = token
        renewed.accessToken = response.accessToken
        renewed.refreshToken = response.refreshToken ?? refreshToken
        renewed.expiresAt = response.expiresIn.map { now.addingTimeInterval($0) }
        return renewed
    }

    struct Response: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: TimeInterval?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    private struct ErrorBody: Decodable {
        let error: String
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
        }
    }

    private static func post(
        _ fields: [String: String], to url: URL, using session: URLSession
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(formEncoded(fields).utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where HTTPTransfer.isTransportFailure(error.code) {
            throw HTTPTransfer.connectionFailure(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
            // A refresh token that was revoked, expired or issued to another
            // client: nothing short of signing in again will help.
            if body?.error == "invalid_grant" || status == 401 {
                throw RemoteFileServiceError.authenticationFailed
            }
            throw OAuthError.providerRefused(body?.errorDescription ?? body?.error ?? "HTTP \(status)")
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    static func formEncoded(_ fields: [String: String]) -> String {
        // The query-value set leaves "+" and "&" alone, which in a form body
        // mean a space and a new field.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.sorted { $0.key < $1.key }
            .map { key, value in
                "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
            }
            .joined(separator: "&")
    }
}

/// Where a connection's token is kept between renewals: the Keychain in the
/// app and the extension, which share it.
public protocol OAuthTokenStore: Sendable {
    func loadOAuthToken(for serverID: UUID) throws -> OAuthToken
    func saveOAuthToken(_ token: OAuthToken, for serverID: UUID) throws
}

extension KeychainCredentialStore: OAuthTokenStore {}

/// Hands out a usable access token for one connection, renewing it when it
/// expires or the server rejects it.
///
/// The app and the extension each hold one of these for the same connection
/// and both may renew. Before renewing, the Keychain is read again: if the
/// other process already did it, its token is taken instead of spending the
/// refresh token a second time — which, for a provider that rotates them,
/// would leave one of the two holding a refresh token that no longer works.
public actor OAuthSession {
    private var token: OAuthToken
    private let serverID: UUID?
    private let store: any OAuthTokenStore
    private let urlSession: URLSession
    private var renewal: Task<OAuthToken, Error>?

    /// - Parameter serverID: the connection whose Keychain item holds the
    ///   token, or nil for one being tried before it is saved, whose renewals
    ///   have nowhere to go.
    public init(
        token: OAuthToken,
        serverID: UUID?,
        store: any OAuthTokenStore = KeychainCredentialStore(),
        urlSession: URLSession = .shared
    ) {
        self.token = token
        self.serverID = serverID
        self.store = store
        self.urlSession = urlSession
    }

    public var provider: OAuthProvider { token.provider }

    public func accessToken() async throws -> String {
        if token.needsRefresh() {
            try await renew()
        }
        return token.accessToken
    }

    /// Called when a request sent with `rejected` came back unauthorized.
    public func accessToken(replacing rejected: String) async throws -> String {
        guard token.accessToken == rejected else { return token.accessToken }
        try await renew()
        return token.accessToken
    }

    private func renew() async throws {
        if let renewal {
            token = try await renewal.value
            return
        }
        if let serverID,
           let stored = try? store.loadOAuthToken(for: serverID),
           stored.accessToken != token.accessToken,
           !stored.needsRefresh() {
            token = stored
            return
        }
        let current = token
        let session = urlSession
        let task = Task { try await OAuthTokenEndpoint.refresh(current, using: session) }
        renewal = task
        defer { renewal = nil }
        let renewed: OAuthToken
        do {
            renewed = try await task.value
        } catch RemoteFileServiceError.authenticationFailed {
            // The app and the extension share one stored token, and a
            // provider that rotates refresh tokens accepts each one once:
            // when both renew at the same moment, the loser is refused while
            // the winner's replacement is already in the store.
            if let serverID,
               let stored = try? store.loadOAuthToken(for: serverID),
               stored.refreshToken != current.refreshToken,
               !stored.needsRefresh() {
                token = stored
                return
            }
            throw RemoteFileServiceError.authenticationFailed
        }
        token = renewed
        if let serverID {
            // A renewal that cannot be stored still works for this process;
            // the other one renews again for itself when it needs to.
            try? store.saveOAuthToken(renewed, for: serverID)
        }
    }
}
