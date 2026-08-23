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

/// Writes down what the extension saw, so the app's poll has something to
/// compare a later listing against.
///
/// Serialized on one queue: the extension lists several directories at once,
/// and the record is one file. Off the calling task, because a listing should
/// not wait on a disk write to hand Finder its results.
enum RemoteDirectoryRecord {
    private static let queue = DispatchQueue(label: "dev.hamasen.directory-record")

    static func record(_ items: [RemoteItem], serverID: UUID, directoryPath: String) {
        queue.async {
            // No store means no app group, which the rest of the extension
            // reports on its own; a missed observation is not worth a second
            // error for the same cause.
            guard let store = try? RemoteDirectorySnapshotStore() else { return }
            store.record(items, serverID: serverID, directoryPath: directoryPath)
        }
    }
}
