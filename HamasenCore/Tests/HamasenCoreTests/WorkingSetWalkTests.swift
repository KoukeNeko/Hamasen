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
        walk.advance(subdirectories: ["photos", "docs"])
        #expect(walk.current?.path == "/docs")
        walk.advance(subdirectories: ["2026"])
        #expect(walk.current?.path == "/photos")
        walk.advance(subdirectories: [])
        // docs/2026 comes after photos, not before: breadth first.
        #expect(walk.current?.path == "/docs/2026")
        walk.advance(subdirectories: [])
        #expect(walk.isFinished)
    }

    @Test
    func oneServerFinishesBeforeTheNextStarts() {
        var walk = WorkingSetWalk(serverIDs: [a, b])
        walk.advance(subdirectories: ["x"])
        // b's root was queued before a/x: the roots come first, then depth 1.
        #expect(walk.current == .init(serverID: b, path: "/", depth: 0))
        walk.advance(subdirectories: [])
        #expect(walk.current == .init(serverID: a, path: "/x", depth: 1))
    }

    /// Beyond the depth limit nothing is queued, and what is there is listed
    /// by Finder when someone opens it, as before.
    @Test
    func doesNotDescendPastTheDepthLimit() {
        var walk = WorkingSetWalk(serverIDs: [a], limits: .init(maximumDepth: 1, maximumDirectories: 100))
        walk.advance(subdirectories: ["one"])
        #expect(walk.current?.depth == 1)
        walk.advance(subdirectories: ["two"])
        #expect(walk.isFinished, "depth 2 must not be queued")
    }

    /// Every directory is a billed request on S3. The cap has to hold even
    /// when the tree would go on.
    @Test
    func stopsAtTheDirectoryLimit() {
        var walk = WorkingSetWalk(serverIDs: [a], limits: .init(maximumDepth: 99, maximumDirectories: 3))
        for _ in 0..<3 {
            #expect(walk.current != nil)
            walk.advance(subdirectories: ["more"])
        }
        #expect(walk.isFinished)
        #expect(walk.queue.isEmpty == false, "the queue is not drained, the walk simply stops")
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
        walk.advance(subdirectories: [])
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
        for _ in 0..<500 { walk.advance(subdirectories: ["x"]) }
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
        walk.advance(subdirectories: ["p", "q"])
        let decoded = try JSONDecoder().decode(WorkingSetWalk.self, from: JSONEncoder().encode(walk))
        #expect(decoded == walk)
        #expect(decoded.current == walk.current)
    }
}
