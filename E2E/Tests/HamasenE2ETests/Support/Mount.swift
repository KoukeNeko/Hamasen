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

/// A server as the extension holds it: one session, reused while it lives
/// and replaced when it dies — ConnectionRegistry's lease. Reads are retried
/// once on a fresh session, as the extension retries fetches; writes are not,
/// since the system retries those itself, after asking what happened.
actor Mount {
    let clients: LaneClients
    private var session: (any RemoteFileService)?
    /// How many sessions were opened, the first included.
    private(set) var sessionsOpened = 0

    init(_ clients: LaneClients) {
        self.clients = clients
    }

    func read<T: Sendable>(_ work: @Sendable (any RemoteFileService) async throws -> T) async throws -> T {
        let service = try await lease()
        do {
            return try await work(service)
        } catch where Self.isConnectionFailure(error) {
            discard()
            return try await work(try await lease())
        }
    }

    func write<T: Sendable>(_ work: @Sendable (any RemoteFileService) async throws -> T) async throws -> T {
        let service = try await lease()
        do {
            return try await work(service)
        } catch {
            if Self.isConnectionFailure(error) { discard() }
            throw error
        }
    }

    func lease() async throws -> any RemoteFileService {
        if let session {
            if await session.isConnected { return session }
            discard()
        }
        let fresh = try await clients.connected()
        sessionsOpened += 1
        session = fresh
        return fresh
    }

    /// Drops the session, so the next operation connects afresh — after a
    /// connection failure, or a credential change the old session predates.
    func discard() {
        guard let stale = session else { return }
        session = nil
        Task { try? await stale.disconnect() }
    }

    func close() async {
        try? await session?.disconnect()
        session = nil
    }

    /// What the registry treats as a dead session rather than an answer.
    static func isConnectionFailure(_ error: Error) -> Bool {
        switch error {
        case RemoteFileServiceError.connectionFailed, RemoteFileServiceError.notConnected:
            return true
        default:
            return false
        }
    }
}

extension E2E {
    /// Runs `body`, failing once `seconds` have passed whether or not it
    /// stops — a client that ignores cancellation is the hang this exists to
    /// catch, and waiting for it would hang the test instead.
    static func withDeadline<T: Sendable>(
        _ seconds: Double, _ what: String, _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            let work = Task {
                do {
                    once.resume(with: .success(try await body()))
                } catch {
                    once.resume(with: .failure(error))
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if once.resume(with: .failure(E2EError.unexpected("\(what) still running after \(Int(seconds)) s"))) {
                    work.cancel()
                }
            }
        }
    }
}

private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    /// Whether this call was the one that resumed.
    @discardableResult
    func resume(with result: Result<T, Error>) -> Bool {
        guard let continuation = lock.withLock({ () -> CheckedContinuation<T, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }) else { return false }
        continuation.resume(with: result)
        return true
    }
}
