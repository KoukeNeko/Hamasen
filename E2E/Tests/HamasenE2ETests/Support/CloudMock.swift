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

/// The cloud mock container: its admin API, and URLSessions whose requests
/// to the real providers' hosts reach it instead.
enum CloudMock {
    /// A session for a cloud client. Every https request it makes is sent to
    /// the mock as http://<E2E.host>:<port>/<host>/<path>, so the clients run
    /// unchanged — same URLs, headers and bodies — against the container.
    static func session(port: Int) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudRewriteProtocol.self]
        configuration.httpAdditionalHeaders = [CloudRewriteProtocol.portHeader: String(port)]
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }

    /// A token pair as a browser sign-in would have left it.
    static func signIn(_ provider: OAuthProvider) async throws -> OAuthToken {
        let body = try await admin("token", ["provider": provider.rawValue])
        guard let access = body["access_token"] as? String,
              let refresh = body["refresh_token"] as? String
        else { throw E2EError.unexpected("cloud mock issued no token: \(body)") }
        let lifetime = (body["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        return OAuthToken(
            provider: provider, client: OAuthClient(clientID: "hamasen-e2e"),
            accessToken: access, refreshToken: refresh, expiresAt: Date().addingTimeInterval(lifetime))
    }

    /// Every token of a provider stops working — the account's password was
    /// changed, or access was revoked in the provider's settings.
    static func revoke(_ provider: OAuthProvider) async throws {
        _ = try await admin("revoke", ["provider": provider.rawValue])
    }

    /// The next `count` requests of a provider are rate-limited.
    static func throttle(_ provider: OAuthProvider, count: Int) async throws {
        _ = try await admin("throttle", ["provider": provider.rawValue, "count": count])
    }

    /// How many times a provider's token endpoint has renewed a token.
    static func refreshCount(_ provider: OAuthProvider) async throws -> Int {
        guard let refreshes = try await stats()["refreshes"] as? [String: Any],
              let count = refreshes[provider.rawValue] as? NSNumber
        else { throw E2EError.unexpected("cloud mock stats carry no refresh count") }
        return count.intValue
    }

    static func stats() async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://\(E2E.host):\(E2E.Port.cloud)/__admin/stats")!)
        request.httpMethod = "GET"
        let (data, _) = try await URLSession.shared.data(for: request)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    @discardableResult
    private static func admin(_ action: String, _ body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://\(E2E.host):\(E2E.Port.cloud)/__admin/\(action)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw E2EError.unexpected("cloud mock \(action): \(String(decoding: data, as: UTF8.self))")
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

/// Sends a session's https requests to the cloud mock, keeping everything
/// about them but the address.
///
/// Redirects are handed back to the outer session to follow, rather than
/// followed here, so the client's session decides what a redirected request
/// carries — the Authorization header in particular — exactly as it would
/// against the real service.
final class CloudRewriteProtocol: URLProtocol, @unchecked Sendable {
    static let portHeader = "X-Hamasen-E2E-Port"

    /// One inner session for every request: it talks plain HTTP to the mock
    /// and is told not to follow redirects itself.
    private static let inner: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.httpMaximumConnectionsPerHost = 32
        return URLSession(configuration: configuration, delegate: RedirectRefuser(), delegateQueue: nil)
    }()

    private var forwarded: URLSessionDataTask?
    private var clientThread: Thread?
    private var runLoopModes: [String] = [RunLoop.Mode.default.rawValue]

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        clientThread = Thread.current
        if let mode = RunLoop.current.currentMode?.rawValue { runLoopModes = [mode, RunLoop.Mode.default.rawValue] }

        guard let url = request.url, let host = url.host,
              let port = request.value(forHTTPHeaderField: Self.portHeader)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        var components = URLComponents()
        components.scheme = "http"
        components.host = E2E.host
        components.port = Int(port)
        components.percentEncodedPath = "/\(host)\(url.path(percentEncoded: true))"
        components.percentEncodedQuery = url.query(percentEncoded: true)

        var rewritten = URLRequest(url: components.url!)
        rewritten.httpMethod = request.httpMethod
        for (field, value) in request.allHTTPHeaderFields ?? [:] where field != Self.portHeader {
            rewritten.setValue(value, forHTTPHeaderField: field)
        }
        rewritten.httpBody = Self.body(of: request)

        let task = Self.inner.dataTask(with: rewritten) { [weak self] data, response, error in
            self?.onClientThread { self?.finish(data: data, response: response, error: error) }
        }
        self.forwarded = task
        task.resume()
    }

    override func stopLoading() {
        forwarded?.cancel()
    }

    private func finish(data: Data?, response: URLResponse?, error: Error?) {
        if let error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard let http = response as? HTTPURLResponse, let originalURL = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        // The response is presented as coming from the https URL the client
        // asked for, so relative redirects and cookies resolve against it.
        let presented = HTTPURLResponse(
            url: originalURL, statusCode: http.statusCode, httpVersion: "HTTP/1.1",
            headerFields: http.allHeaderFields as? [String: String])!
        if (300...399).contains(http.statusCode),
           let location = http.value(forHTTPHeaderField: "Location"),
           let target = URL(string: location, relativeTo: originalURL)?.absoluteURL {
            var redirected = URLRequest(url: target)
            redirected.httpMethod = http.statusCode == 307 || http.statusCode == 308 ? request.httpMethod : "GET"
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: presented)
            // What Apple's own sample protocol does after handing a redirect
            // over: this load is finished, and the session starts the next.
            client?.urlProtocol(self, didFailWithError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            return
        }
        client?.urlProtocol(self, didReceive: presented, cacheStoragePolicy: .notAllowed)
        if let data, !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }

    /// Calls into the URL loading system belong on the thread that started
    /// the load.
    private func onClientThread(_ work: @escaping () -> Void) {
        guard let clientThread else { return work() }
        let box = WorkBox(work)
        box.perform(#selector(WorkBox.run), on: clientThread, with: nil, waitUntilDone: false, modes: runLoopModes)
    }

    /// Uploads reach a protocol as a stream rather than `httpBody`.
    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        while true {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

private final class WorkBox: NSObject {
    private let work: () -> Void
    init(_ work: @escaping () -> Void) { self.work = work }
    @objc func run() { work() }
}

private final class RedirectRefuser: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
