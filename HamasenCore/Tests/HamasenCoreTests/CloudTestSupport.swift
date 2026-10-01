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
@testable import HamasenCore

/// A request as a fake cloud backend sees it, body included.
struct StubRequest {
    let method: String
    let url: URL
    let headers: [String: String]
    let body: Data

    var path: String { url.path(percentEncoded: false) }

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    func query(_ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    var json: [String: Any] {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }

    /// The bearer token, without its scheme.
    var bearer: String? {
        header("Authorization").flatMap { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : nil }
    }
}

struct StubResponse {
    var status: Int
    var headers: [String: String] = [:]
    var body: Data = Data()

    static func json(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> StubResponse {
        var headers = headers
        headers["Content-Type"] = "application/json"
        return StubResponse(
            status: status, headers: headers,
            body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }

    static func status(_ status: Int) -> StubResponse { StubResponse(status: status) }
}

/// Routes every request of one URLSession to one handler, so tests running
/// in parallel each talk to their own fake.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (StubRequest) -> StubResponse

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    private static let routeHeader = "X-Stub-Route"

    /// A session whose requests all reach `handler`.
    static func session(handler: @escaping Handler) -> URLSession {
        let route = UUID().uuidString
        lock.withLock { handlers[route] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = [routeHeader: route]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let headers = request.allHTTPHeaderFields ?? [:]
        let route = headers.first { $0.key.caseInsensitiveCompare(Self.routeHeader) == .orderedSame }?.value
        guard let route, let handler = Self.lock.withLock({ Self.handlers[route] }), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let stubbed = StubRequest(
            method: request.httpMethod ?? "GET", url: url, headers: headers, body: Self.body(of: request))
        let reply = handler(stubbed)
        let response = HTTPURLResponse(
            url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// Uploads arrive as a stream rather than `httpBody`.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// Answers the token endpoint of whichever provider is under test, issuing
/// a new access token for every refresh, and counts the refreshes.
final class StubTokenIssuer: @unchecked Sendable {
    private let lock = NSLock()
    private var issued = 0
    private(set) var currentToken = "access-0"

    var refreshCount: Int { lock.withLock { issued } }

    func isTokenRequest(_ request: StubRequest) -> Bool {
        request.url.path.hasSuffix("/token")
    }

    func handle(_ request: StubRequest) -> StubResponse {
        let form = String(decoding: request.body, as: UTF8.self)
        guard form.contains("grant_type=refresh_token"), form.contains("refresh_token=refresh-token") else {
            return .json(["error": "invalid_grant"], status: 400)
        }
        let token: String = lock.withLock {
            issued += 1
            currentToken = "access-\(issued)"
            return currentToken
        }
        return .json(["access_token": token, "expires_in": 3600, "token_type": "Bearer"])
    }

    func accepts(_ request: StubRequest) -> Bool {
        lock.withLock { request.bearer == currentToken }
    }
}

enum CloudFixtures {
    static func token(provider: OAuthProvider, access: String = "access-0", expiresIn: TimeInterval = 3600) -> OAuthToken {
        OAuthToken(
            provider: provider,
            client: OAuthClient(clientID: "client-id"),
            accessToken: access,
            refreshToken: "refresh-token",
            expiresAt: Date().addingTimeInterval(expiresIn))
    }

    static func config(_ transferProtocol: ServerConfig.TransferProtocol, remotePath: String = "/") -> ServerConfig {
        ServerConfig(
            name: "雲端測試",
            transferProtocol: transferProtocol,
            host: transferProtocol.oauthProvider!.apiHost,
            port: 443,
            username: "someone@example.com",
            authenticationMethod: .oauth,
            remotePath: remotePath)
    }

    /// A Keychain store under a group no test process is entitled to, so a
    /// renewed token has nowhere to be written and nothing leaks between
    /// tests through the real Keychain.
    static let keychain = KeychainCredentialStore(service: "dev.hamasen.tests", accessGroup: "invalid.tests")

    static func temporaryFile(_ contents: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "cloud-\(UUID().uuidString)")
        try contents.write(to: url)
        return url
    }

    static func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "cloud-\(UUID().uuidString)")
    }

    static func bytes(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    }
}
