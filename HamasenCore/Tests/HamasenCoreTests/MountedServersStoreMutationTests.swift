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

@Suite("MountedServersStore mutations")
struct MountedServersStoreMutationTests {
    private func makeStore() -> MountedServersStore {
        MountedServersStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("mounted-\(UUID().uuidString).json"))
    }

    /// The extension unmounts a server; the app then mounts another. The
    /// app's write must not bring the first back.
    @Test
    func addingByDeltaDoesNotUndoAnUnmount() throws {
        let store = makeStore()
        let kept = UUID(), unmountedByFinder = UUID(), newlyMounted = UUID()
        try store.saveMountedServerIDs([kept, unmountedByFinder])
        try store.removeMountedServer(unmountedByFinder)

        let result = try store.addMountedServers([newlyMounted])
        #expect(result == [kept, newlyMounted])
        #expect(try store.loadMountedServerIDs() == [kept, newlyMounted])
    }

    @Test
    func removingAServerThatIsNotMountedChangesNothing() throws {
        let store = makeStore()
        let mounted = UUID()
        try store.saveMountedServerIDs([mounted])
        #expect(try store.removeMountedServer(UUID()) == [mounted])
    }

    /// Both processes mutate at once; every change must land.
    @Test
    func concurrentAddsAreAllKept() async throws {
        let store = makeStore()
        let ids = (0..<40).map { _ in UUID() }
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { _ = try? store.addMountedServers([id]) }
            }
        }
        #expect(try store.loadMountedServerIDs() == Set(ids))
    }
}
