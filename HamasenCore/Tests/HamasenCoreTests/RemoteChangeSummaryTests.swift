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

@Suite("RemoteChangeSummary")
struct RemoteChangeSummaryTests {
    private let server = UUID()

    private func change(
        path: String = "/docs", added: [String] = [], updated: [String] = [], removed: [String] = []
    ) -> RemoteDirectorySnapshot.Change {
        .init(serverID: server, directoryPath: path,
              addedNames: added, updatedNames: updated, removedNames: removed)
    }

    @Test
    func nothingHappenedIsNoNotification() {
        #expect(RemoteChangeSummary(serverName: "NAS", changes: []) == nil)
        #expect(RemoteChangeSummary(serverName: "NAS", changes: [change()]) == nil)
    }

    /// One file is worth naming: it is what the person will look for.
    @Test
    func oneFileIsNamed() throws {
        let summary = try #require(
            RemoteChangeSummary(serverName: "NAS", changes: [change(added: ["report.pdf"])]))
        #expect(summary.title == "NAS")
        #expect(summary.message.contains("report.pdf"))
    }

    @Test
    func oneFileSaysWhichWayItChanged() throws {
        let added = try #require(
            RemoteChangeSummary(serverName: "NAS", changes: [change(added: ["a"])]))
        let updated = try #require(
            RemoteChangeSummary(serverName: "NAS", changes: [change(updated: ["a"])]))
        let removed = try #require(
            RemoteChangeSummary(serverName: "NAS", changes: [change(removed: ["a"])]))
        #expect(added.message != updated.message)
        #expect(updated.message != removed.message)
    }

    /// A sync touching twenty files is one event to the person watching. One
    /// notification per file is how the feature gets switched off.
    @Test
    func manyFilesAreCountedNotListed() throws {
        let summary = try #require(RemoteChangeSummary(
            serverName: "NAS",
            changes: [
                change(added: ["report.pdf", "notes.txt", "budget.xlsx"]),
                change(path: "/other", updated: ["photo.heic"]),
            ]))
        #expect(summary.message.contains("3"))
        #expect(summary.message.contains("report.pdf") == false,
                "names are not listed once there are several")
    }

    @Test
    func changesAcrossDirectoriesBecomeOneNotification() throws {
        let summary = try #require(RemoteChangeSummary(
            serverName: "NAS",
            changes: [
                change(path: "/a", added: ["one"]),
                change(path: "/b", added: ["two"]),
            ]))
        #expect(summary.message.contains("2"))
    }

    /// A directory with nothing in it must not drag a notification out of an
    /// otherwise quiet round.
    @Test
    func emptyChangesAreIgnoredAmongRealOnes() throws {
        let summary = try #require(RemoteChangeSummary(
            serverName: "NAS", changes: [change(), change(added: ["real"]), change()]))
        #expect(summary.message.contains("real"))
    }
}
