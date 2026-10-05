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

/// Writes down what Finder was shown, so the app's poll has something to
/// compare a later listing against.
///
/// Only Finder's listings, not the background walk's: the poll re-checks the
/// folders somebody has opened, and those are recorded when they are opened.
/// Recording the walk as well would move the baseline forward daily, so a
/// change made between two openings of a folder would go unreported.
///
/// Off the calling task, because a listing should not wait on a disk write to
/// hand Finder its results, and on a concurrent queue because the store
/// already serialises writers per server across both processes.
enum RemoteDirectoryRecord {
    private static let log = HamasenLog(category: "directory-record")
    private static let queue = DispatchQueue(label: "dev.hamasen.directory-record", attributes: .concurrent)

    static func record(_ items: [RemoteItem], serverID: UUID, directoryPath: String) {
        queue.async {
            _ = recordNow(items, serverID: serverID, directoryPath: directoryPath)
        }
    }

    /// Records the listing and says what changed since the last one, for the
    /// caller that has to tell the system about deletions.
    static func changes(
        afterRecording items: [RemoteItem], serverID: UUID, directoryPath: String
    ) async -> RemoteDirectorySnapshot.Change? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: recordNow(items, serverID: serverID, directoryPath: directoryPath))
            }
        }
    }

    /// Names in the last recorded listing that `items` no longer has, without
    /// recording anything. For the walk, which reports what it finds but
    /// leaves the baseline where the last opening put it. Empty for a
    /// directory with no record: nothing is known to have gone.
    ///
    /// The walk also keeps its own record (`walkRecord`), which it does
    /// replace: a folder only the walk has seen still gets its removals
    /// reported, from one walk to the next. Reporting a name twice is
    /// harmless; missing one leaves a deleted file in Finder and Spotlight.
    static func removedNames(from items: [RemoteItem], serverID: UUID, directoryPath: String) -> [String] {
        var removed: Set<String> = []
        if let previous = try? RemoteDirectorySnapshotStore()
            .snapshot(serverID: serverID, directoryPath: directoryPath) {
            removed.formUnion(RemoteDirectorySnapshot.change(
                from: previous, to: RemoteDirectorySnapshot(path: directoryPath, items: items), serverID: serverID
            ).removedNames)
        }
        do {
            let walkChange = try RemoteDirectorySnapshotStore.walkRecord()
                .record(items, serverID: serverID, directoryPath: directoryPath)
            removed.formUnion(walkChange.removedNames)
        } catch {
            log.error("Could not record the walk of \(directoryPath) on \(serverID): \(error.localizedDescription)")
        }
        return removed.sorted()
    }

    private static func recordNow(
        _ items: [RemoteItem], serverID: UUID, directoryPath: String
    ) -> RemoteDirectorySnapshot.Change? {
        // No store means no app group, which the rest of the extension
        // reports on its own; a missed observation is not worth a second
        // error for the same cause.
        guard let store = try? RemoteDirectorySnapshotStore() else { return nil }
        do {
            return try store.record(items, serverID: serverID, directoryPath: directoryPath)
        } catch {
            log.error("Could not record \(directoryPath) on \(serverID): \(error.localizedDescription)")
            return nil
        }
    }
}
