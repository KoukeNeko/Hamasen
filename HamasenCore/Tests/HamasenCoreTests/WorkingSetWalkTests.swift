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

@Suite("WorkingSetWalk")
struct WorkingSetWalkTests {
    private let a = UUID()
    private let b = UUID()

    @Test
    func startsAtEveryServersRoot() {
        let walk = WorkingSetWalk(serverIDs: [a, b])
        #expect(walk.current == .init(serverID: a, path: "/", depth: 0))
        #expect(walk.queue.count == 2)
        #expect(walk.isFinished == false)
    }

    @Test
    func visitsBreadthFirst() {
        var walk = WorkingSetWalk(serverIDs: [a])
        walk.advance(itemCount: 0, subdirectories: ["photos", "docs"])
        #expect(walk.current?.path == "/docs")
        walk.advance(itemCount: 0, subdirectories: ["2026"])
        #expect(walk.current?.path == "/photos")
        walk.advance(itemCount: 0, subdirectories: [])
        // docs/2026 comes after photos, not before: breadth first.
        #expect(walk.current?.path == "/docs/2026")
        walk.advance(itemCount: 0, subdirectories: [])
        #expect(walk.isFinished)
    }

    @Test
    func oneServerFinishesBeforeTheNextStarts() {
        var walk = WorkingSetWalk(serverIDs: [a, b])
        walk.advance(itemCount: 0, subdirectories: ["x"])
        // b's root was queued before a/x: the roots come first, then depth 1.
        #expect(walk.current == .init(serverID: b, path: "/", depth: 0))
        walk.advance(itemCount: 0, subdirectories: [])
        #expect(walk.current == .init(serverID: a, path: "/x", depth: 1))
    }

    /// Beyond the depth limit nothing is queued, and what is there is listed
    /// by Finder when someone opens it, as before.
    @Test
    func doesNotDescendPastTheDepthLimit() {
        var walk = WorkingSetWalk(serverIDs: [a], limits: .init(maximumDepth: 1, maximumDirectories: 100, maximumItems: 99))
        walk.advance(itemCount: 0, subdirectories: ["one"])
        #expect(walk.current?.depth == 1)
        walk.advance(itemCount: 0, subdirectories: ["two"])
        #expect(walk.isFinished, "depth 2 must not be queued")
    }

    /// Every directory is a billed request on S3. The cap has to hold even
    /// when the tree would go on.
    @Test
    func stopsAtTheDirectoryLimit() {
        var walk = WorkingSetWalk(serverIDs: [a], limits: .init(maximumDepth: 99, maximumDirectories: 3, maximumItems: 99))
        for _ in 0..<3 {
            #expect(walk.current != nil)
            walk.advance(itemCount: 0, subdirectories: ["more"])
        }
        #expect(walk.isFinished)
        #expect(walk.directoriesListed == 3)
    }

    /// Spotlight indexes nothing under a dot directory, so listing one is a
    /// request that buys nothing.
    @Test
    func hiddenDirectoriesAreNotWalked() {
        var walk = WorkingSetWalk(serverIDs: [a])
        walk.advance(itemCount: 3, subdirectories: [".cache", "docs", ".vscode-server"])
        #expect(walk.queue.map(\.path) == ["/docs"])
    }

    /// A thousand files per folder reaches the Mac's limit long before the
    /// server's: the item budget ends that server's walk on its own.
    @Test
    func stopsAtTheItemLimit() {
        var walk = WorkingSetWalk(serverIDs: [a, b], limits: .init(maximumDepth: 99, maximumDirectories: 99, maximumItems: 10))
        walk.advance(itemCount: 4, subdirectories: ["x", "y"])     // a: 4 of 10
        walk.advance(itemCount: 1, subdirectories: [])             // b: done
        walk.advance(itemCount: 6, subdirectories: ["deeper"])     // a/x: 10 of 10, a/y dropped
        #expect(walk.isFinished)
        #expect(walk.directoriesListed == 3)
    }

    /// One server with a node_modules in it must not spend the budget that
    /// was meant to get the others listed.
    @Test
    func eachServerHasItsOwnDirectoryBudget() {
        var walk = WorkingSetWalk(serverIDs: [a, b], limits: .init(maximumDepth: 99, maximumDirectories: 2, maximumItems: 99))
        walk.advance(itemCount: 0, subdirectories: ["x", "y", "z"])      // a: 1 of 2
        walk.advance(itemCount: 0, subdirectories: [])                   // b: 1 of 2
        walk.advance(itemCount: 0, subdirectories: ["deeper"])           // a/x: 2 of 2, a/y and a/z are dropped
        #expect(walk.queue.contains { $0.serverID == a } == false)
        #expect(walk.isFinished, "b has budget left but nothing queued")

        var other = WorkingSetWalk(serverIDs: [a, b], limits: .init(maximumDepth: 99, maximumDirectories: 1, maximumItems: 99))
        other.advance(itemCount: 0, subdirectories: ["x"])               // a is spent; a/x never queued
        #expect(other.current == .init(serverID: b, path: "/", depth: 0))
        other.skipCurrent()                                // b is spent too
        #expect(other.isFinished)
    }

    @Test
    func anUnreadableDirectoryIsSkippedNotFatal() {
        var walk = WorkingSetWalk(serverIDs: [a, b])
        walk.skipCurrent()
        #expect(walk.current?.serverID == b)
        #expect(walk.directoriesListed == 1, "a skip still counts against the budget")
    }

    // MARK: - Tokens

    @Test
    func theTokenNamesThisWalkAtThisStep() {
        var walk = WorkingSetWalk(serverIDs: [a])
        let atStart = walk.token
        #expect(walk.matches(atStart))
        walk.advance(itemCount: 0, subdirectories: [])
        #expect(walk.matches(atStart) == false, "a step behind is not a match")
        #expect(walk.matches(walk.token))
    }

    @Test
    func aTokenFromAnotherWalkDoesNotMatch() {
        let first = WorkingSetWalk(serverIDs: [a])
        let second = WorkingSetWalk(serverIDs: [a])
        #expect(second.matches(first.token) == false)
    }

    /// The system refuses a page over 500 bytes; a UUID and an integer are a
    /// long way under.
    @Test
    func theTokenFitsThePageLimit() {
        var walk = WorkingSetWalk(serverIDs: [a])
        for _ in 0..<500 { walk.advance(itemCount: 0, subdirectories: ["x"]) }
        let encoded = WorkingSetWalk.encode(walk.token)
        #expect(encoded.count < 500)
        #expect(WorkingSetWalk.decode(encoded) == walk.token)
    }

    @Test
    func anUnreadableTokenDecodesToNil() {
        #expect(WorkingSetWalk.decode(Data("garbage".utf8)) == nil)
        #expect(WorkingSetWalk.decode(Data()) == nil)
    }

    /// The walk is stored in the app group between pages, so it has to
    /// survive a round trip through its own encoding.
    @Test
    func theWalkItselfRoundTrips() throws {
        var walk = WorkingSetWalk(serverIDs: [a, b])
        walk.advance(itemCount: 0, subdirectories: ["p", "q"])
        let decoded = try JSONDecoder().decode(WorkingSetWalk.self, from: JSONEncoder().encode(walk))
        #expect(decoded == walk)
        #expect(decoded.current == walk.current)
    }

    // MARK: - When the next walk is due

    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let oneHour: TimeInterval = 60 * 60

    /// Between pages the walk is in progress, and a signal arriving then
    /// must not start a second one over the top of it.
    @Test
    func aWalkInProgressIsNotStale() {
        let walk = WorkingSetWalk(serverIDs: [a], startedAt: start)
        #expect(walk.isStale(at: start + oneHour) == false)
    }

    /// The extension can be stopped between pages and never asked for the
    /// next one. That walk would otherwise block every later one.
    @Test
    func anAbandonedWalkGoesStaleFromItsStart() {
        let walk = WorkingSetWalk(serverIDs: [a], startedAt: start)
        #expect(walk.isStale(at: start + WorkingSetWalk.repeatInterval))
    }

    @Test
    func aFinishedWalkGoesStaleFromItsCompletion() {
        var walk = WorkingSetWalk(serverIDs: [a], startedAt: start)
        walk.advance(itemCount: 0, subdirectories: [])
        walk.markCompleted(at: start + oneHour)
        #expect(walk.isFinished)
        #expect(walk.isStale(at: start + WorkingSetWalk.repeatInterval) == false)
        #expect(walk.isStale(at: start + oneHour + WorkingSetWalk.repeatInterval))
    }

    /// The store answers for a walk that was never run at all, which is the
    /// state of every domain created before walks existed.
    @Test
    func theStoreFindsAWalkDueWhenThereIsNone() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("walk-\(UUID().uuidString).json")
        let store = WorkingSetWalkStore(fileURL: fileURL)
        #expect(store.isWalkDue(at: start))

        var walk = WorkingSetWalk(serverIDs: [a], startedAt: start)
        walk.markCompleted(at: start)
        try store.save(walk)
        #expect(store.isWalkDue(at: start + oneHour) == false)
        #expect(store.isWalkDue(at: start + WorkingSetWalk.repeatInterval))

        store.clear()
        #expect(store.isWalkDue(at: start + oneHour))
    }

    // MARK: - The walk as change batches

    private func makeStore() -> WorkingSetWalkStore {
        WorkingSetWalkStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("walk-\(UUID().uuidString).json"))
    }

    /// With no walk on file the first change batch begins one, which is how
    /// the daily walk starts without an expired anchor.
    @Test
    func aDueWalkStartsInTheNextChangeBatch() {
        let store = makeStore()
        let walk = store.walkForChangeBatch(after: nil, serverIDs: [a], limits: .default, at: start)
        #expect(walk?.current == .init(serverID: a, path: "/", depth: 0))
    }

    @Test
    func aWalkThatIsNotDueIsNotStarted() throws {
        let store = makeStore()
        var walk = WorkingSetWalk(serverIDs: [a], startedAt: start)
        walk.advance(itemCount: 0, subdirectories: [])
        walk.markCompleted(at: start)
        try store.save(walk)
        #expect(store.walkForChangeBatch(after: walk.token, serverIDs: [a], limits: .default, at: start + oneHour) == nil)
        #expect(store.walkForChangeBatch(after: nil, serverIDs: [a], limits: .default, at: start + oneHour) == nil)
    }

    /// The anchor names the walk; the batch after this one resumes it.
    @Test
    func anUnfinishedWalkIsResumedFromItsToken() throws {
        let store = makeStore()
        var walk = WorkingSetWalk(serverIDs: [a], startedAt: start)
        walk.advance(itemCount: 0, subdirectories: ["x"])
        try store.save(walk)
        let resumed = store.walkForChangeBatch(after: walk.token, serverIDs: [a], limits: .default, at: start + oneHour)
        #expect(resumed == walk)
    }

    /// A saved step the system never recorded leaves the anchor one behind.
    /// Refusing it would strand the walk until it goes stale.
    @Test
    func aTokenOneStepBehindStillResumesTheSameWalk() throws {
        let store = makeStore()
        var walk = WorkingSetWalk(serverIDs: [a], startedAt: start)
        let behind = walk.token
        walk.advance(itemCount: 0, subdirectories: ["x"])
        try store.save(walk)
        #expect(store.walkForChangeBatch(after: behind, serverIDs: [a], limits: .default, at: start + oneHour) == walk)
    }

    /// Another walk (the first import pages through its own) replaced the
    /// file. This anchor's walk is gone, and the newer one is not ours to
    /// step through.
    @Test
    func aTokenFromAnotherWalkDoesNotResumeIt() throws {
        let store = makeStore()
        let other = WorkingSetWalk(serverIDs: [a], startedAt: start)
        try store.save(WorkingSetWalk(serverIDs: [a], startedAt: start))
        #expect(store.walkForChangeBatch(after: other.token, serverIDs: [a], limits: .default, at: start + oneHour) == nil)
    }

    /// The anchor of a batch carries the token as JSON beside the list
    /// digest, and the header refuses more than 500 bytes.
    @Test
    func theAnchorAWalkStepEndsOnFitsTheLimit() {
        var walk = WorkingSetWalk(serverIDs: [a])
        for _ in 0..<500 { walk.advance(itemCount: 0, subdirectories: ["x"]) }
        let anchor = WorkingSetAnchor(serverList: String(repeating: "f", count: 32), walk: walk.token)
        #expect(anchor.encoded().count < 500)
    }
}
