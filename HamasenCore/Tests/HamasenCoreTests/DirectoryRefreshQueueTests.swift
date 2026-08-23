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

@Suite("DirectoryRefreshQueue")
struct DirectoryRefreshQueueTests {
    private let server = UUID()

    private func makeQueue() -> DirectoryRefreshQueue {
        DirectoryRefreshQueue(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("refresh-\(UUID().uuidString).json"))
    }

    @Test
    func startsEmpty() throws {
        #expect(try makeQueue().drain().isEmpty)
    }

    /// Two writers in two processes add to the same queue; neither is
    /// allowed to drop what the other put there.
    @Test
    func accumulatesAcrossWrites() throws {
        let queue = makeQueue()
        try queue.enqueue([.init(serverID: server, path: "/a")])
        try queue.enqueue([.init(serverID: server, path: "/b"), .init(serverID: server, path: "/a")])
        #expect(try queue.drain() == [.init(serverID: server, path: "/a"), .init(serverID: server, path: "/b")])
    }

    /// Draining is what marks the directories as reported, so a second drain
    /// must not report them again.
    @Test
    func drainingEmptiesTheQueue() throws {
        let queue = makeQueue()
        try queue.enqueue([.init(serverID: server, path: "/a")])
        _ = try queue.drain()
        #expect(try queue.drain().isEmpty)
    }
}
