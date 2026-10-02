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

/// Changes server state the way an administrator would: through
/// `docker compose`, using the commands each container provides under /e2e.
enum ServerControl {
    @discardableResult
    static func exec(_ service: String, _ command: String, _ arguments: String...) async throws -> String {
        try await compose(["exec", "-T", service, "/e2e/\(command)"] + arguments)
    }

    /// Restarts a service and waits until it reports healthy again — what an
    /// outage, a reboot or an update looks like from the client's side.
    static func restart(_ service: String) async throws {
        _ = try await compose(["restart", service])
        _ = try await compose(["up", "-d", "--wait", service])
    }

    static func stop(_ service: String) async throws {
        _ = try await compose(["stop", service])
    }

    static func start(_ service: String) async throws {
        _ = try await compose(["up", "-d", "--wait", service])
    }

    static func compose(_ arguments: [String]) async throws -> String {
        // A stack on another host is driven through SSH, from the copy
        // scripts/e2e.sh put there.
        if let sshHost = ProcessInfo.processInfo.environment["HAMASEN_E2E_SSH"] {
            let directory = ProcessInfo.processInfo.environment["HAMASEN_E2E_REMOTE_DIR"] ?? "hamasen-e2e"
            let command = (["cd", directory, "&&", "docker", "compose", "-p", "hamasen-e2e", "-f", "docker-compose.yml"]
                .map { $0 == "&&" ? $0 : shellQuoted($0) } + arguments.map(shellQuoted)).joined(separator: " ")
            return try await run(["ssh", "-o", "BatchMode=yes", sshHost, command])
        }
        let composeFile = E2E.directory.appending(path: "docker-compose.yml").path
        return try await run(
            ["docker", "compose", "-p", "hamasen-e2e", "-f", composeFile] + arguments)
    }

    private static func shellQuoted(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs a command to completion off the cooperative pool, returning what
    /// it printed and failing on a non-zero exit.
    static func run(_ command: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = command
            var environment = ProcessInfo.processInfo.environment
            // Docker Desktop and OrbStack install the CLI here, which a test
            // process launched by SwiftPM does not always have on its PATH.
            environment["PATH"] = (environment["PATH"] ?? "") + ":/usr/local/bin:/opt/homebrew/bin"
            process.environment = environment
            // Drained as it arrives: a pipe left unread fills at 64 KB and
            // blocks the child, which then never exits.
            let output = Pipe()
            let collected = Collected()
            output.fileHandleForReading.readabilityHandler = { handle in
                collected.append(handle.availableData)
            }
            process.standardOutput = output
            process.standardError = output
            process.terminationHandler = { finished in
                output.fileHandleForReading.readabilityHandler = nil
                collected.append(output.fileHandleForReading.readDataToEndOfFile())
                let text = collected.text
                if finished.terminationStatus == 0 {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(throwing: E2EError.command(
                        command.joined(separator: " "), finished.terminationStatus, text))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.withLock { data.append(chunk) }
    }

    var text: String {
        lock.withLock { String(decoding: data, as: UTF8.self) }
    }
}
