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

    /// A refresh is taken off the queue when it was reported, not before: one
    /// that failed, or one whose process died, must still be there.
    @Test
    func pendingLeavesTheQueueAsItWas() throws {
        let queue = makeQueue()
        try queue.enqueue([.init(serverID: server, path: "/a")])
        #expect(try queue.pending() == [.init(serverID: server, path: "/a")])
        #expect(try queue.pending() == [.init(serverID: server, path: "/a")])
    }

    @Test
    func removingTakesOnlyWhatWasReported() throws {
        let queue = makeQueue()
        try queue.enqueue([.init(serverID: server, path: "/a"), .init(serverID: server, path: "/b")])
        let reported = try queue.pending()
        // Queued after the read: not reported, so it must survive.
        try queue.enqueue([.init(serverID: server, path: "/c")])
        try queue.remove(reported)
        #expect(try queue.pending() == [.init(serverID: server, path: "/c")])
    }

    @Test
    func removingWhatIsNotQueuedIsHarmless() throws {
        let queue = makeQueue()
        try queue.remove([.init(serverID: server, path: "/a")])
        #expect(try queue.pending().isEmpty)
    }

    /// The app and the extension enqueue at once. Without the lock each reads
    /// the old set and the second write drops the first's entry.
    @Test
    func concurrentEnqueuesAreAllKept() async throws {
        let queue = makeQueue()
        let serverID = server
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<50 {
                group.addTask {
                    try? queue.enqueue([.init(serverID: serverID, path: "/d\(index)")])
                }
            }
        }
        #expect(try queue.pending().count == 50)
    }

    @Test
    func anUnreadableQueueIsEmptyRatherThanStuck() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("refresh-\(UUID().uuidString).json")
        try Data("not json".utf8).write(to: fileURL)
        let queue = DirectoryRefreshQueue(fileURL: fileURL)
        #expect(try queue.pending().isEmpty)
        try queue.enqueue([.init(serverID: server, path: "/a")])
        #expect(try queue.pending().count == 1)
    }

    /// A directory queued again while its earlier request is being reported
    /// is a second change; removing the first must leave it queued.
    @Test
    func aRefreshQueuedAgainWhileReportedStays() throws {
        let queue = makeQueue()
        let entry = DirectoryRefreshQueue.Entry(serverID: server, path: "/a")
        try queue.enqueue([entry])
        let reported = try queue.snapshot()
        try queue.enqueue([entry])
        try queue.remove(reported: reported)
        #expect(try queue.pending() == [entry])
    }
}
