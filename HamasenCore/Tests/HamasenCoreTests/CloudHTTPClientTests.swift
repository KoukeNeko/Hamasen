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

/// When the cloud drives' shared HTTP client sends a request again. The rule
/// for which answers mean "later" and how long to wait is HTTPTransfer's,
/// which S3 follows as well.
@Suite("CloudHTTPClient")
struct CloudHTTPClientTests {
    /// Answers requests from a script, one reply each, and counts them.
    private final class ScriptedServer: @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [StubResponse]
        private var served = 0

        init(_ replies: [StubResponse]) {
            self.replies = replies
        }

        var requestCount: Int { lock.withLock { served } }

        func reply(_ request: StubRequest) -> StubResponse {
            lock.withLock {
                served += 1
                return replies.isEmpty ? .status(200) : replies.removeFirst()
            }
        }
    }

    private static func client(_ server: ScriptedServer) -> CloudHTTPClient {
        let session = StubURLProtocol.session { server.reply($0) }
        return CloudHTTPClient(
            auth: OAuthSession(
                token: CloudFixtures.token(provider: .google), serverID: nil,
                store: CloudFixtures.keychain, urlSession: session),
            urlSession: session, ownsSession: false)
    }

    private static let request = URLRequest.cloud(URL(string: "https://www.googleapis.com/drive/v3/about")!)

    @Test("429 與 5xx 依 Retry-After 等待後重試")
    func retriesRateLimitsAndServiceFailuresAsTold() async throws {
        let server = ScriptedServer([
            StubResponse(status: 429, headers: ["Retry-After": "0"]),
            StubResponse(status: 503, headers: ["Retry-After": "0"]),
        ])
        let (_, response) = try await Self.client(server).send(Self.request)

        #expect(response.statusCode == 200)
        #expect(server.requestCount == 3)
    }

    @Test("Retry-After 超過一分鐘時不在請求內等待")
    func reportsAnAnswerThatAsksForTooLongAWait() async throws {
        let server = ScriptedServer([StubResponse(status: 503, headers: ["Retry-After": "3600"])])
        let (_, response) = try await Self.client(server).send(Self.request)

        #expect(response.statusCode == 503)
        #expect(server.requestCount == 1)
    }
}
