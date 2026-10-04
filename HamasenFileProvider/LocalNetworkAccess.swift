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
import Network
import os

/// Local Network privacy treats this extension as its own identity, apart
/// from the app. Without the person's consent the kernel drops every
/// connection it makes to a LAN host, which reads as "No route to host" —
/// the same as a server that is switched off — so the cause has to be asked
/// for separately before it can be reported.
enum LocalNetworkAccess {
    /// A connection the system refused because Local Network access is off.
    struct DeniedError: LocalizedError {
        var errorDescription: String? {
            String(localized: "沒有「本地網路」權限，無法連線到區域網路上的伺服器。到「系統設定」>「隱私權與安全性」>「本地網路」開啟 HamasenFileProvider。")
        }
    }

    /// Whether Local Network privacy is what keeps this process from the
    /// host. Only asked after a connection has failed: when access is
    /// allowed it opens, and immediately closes, one more connection.
    static func isDenied(host: String, port: Int) async -> Bool {
        guard !host.isEmpty, let port = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port.rawValue != 0 else {
            return false
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let answer = OSAllocatedUnfairLock<CheckedContinuation<Bool, Never>?>(initialState: nil)
        func finish(_ denied: Bool) {
            let continuation = answer.withLock { pending in
                defer { pending = nil }
                return pending
            }
            continuation?.resume(returning: denied)
            connection.cancel()
        }
        return await withCheckedContinuation { continuation in
            answer.withLock { $0 = continuation }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(false)
                case .waiting, .failed:
                    finish(connection.currentPath?.unsatisfiedReason == .localNetworkDenied)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
            // A host that neither answers nor is refused leaves the
            // connection preparing; that is not a denial.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { finish(false) }
        }
    }
}
