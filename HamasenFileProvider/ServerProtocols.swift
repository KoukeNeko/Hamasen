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
import HamasenCore

/// Each server's protocol, cached for the extension.
///
/// Every item reports its server's protocol, and items are vended in bulk,
/// so the server list is read once rather than per item. A server keeps its
/// protocol for life, which is why the cache is only reread for a server it
/// has not seen.
enum ServerProtocols {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var cached: [UUID: ServerConfig.TransferProtocol] = [:]

    static func transferProtocol(of serverID: UUID) -> ServerConfig.TransferProtocol? {
        lock.lock()
        defer { lock.unlock() }

        if let known = cached[serverID] { return known }
        // An unreadable list leaves the item without a protocol, which only
        // hides the entries that need one.
        if let servers = try? ServerConfigStore().loadServers() {
            cached = Dictionary(servers.map { ($0.id, $0.transferProtocol) }, uniquingKeysWith: { first, _ in first })
        }
        return cached[serverID]
    }
}
