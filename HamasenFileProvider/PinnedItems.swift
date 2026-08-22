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

import FileProvider
import Foundation
import HamasenCore

/// The pinned set, cached for the extension.
///
/// Every item the provider vends has to say whether it is pinned, and items
/// are vended in bulk during enumeration — reading the file each time would
/// put a disk round trip in the middle of every listing. The cache is short
/// lived rather than permanent because the app may pin from its own side.
enum PinnedItems {
    private static let lifetime: TimeInterval = 2
    private static let lock = NSLock()
    private nonisolated(unsafe) static var cached: Set<String> = []
    private nonisolated(unsafe) static var readAt: Date = .distantPast

    static func contains(_ identifier: NSFileProviderItemIdentifier) -> Bool {
        current().contains(identifier.rawValue)
    }

    static func current() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }

        if Date().timeIntervalSince(readAt) < lifetime {
            return cached
        }
        // A failure here must not make everything look unpinned, which would
        // hand the cache sweep permission to drop content the user kept.
        if let identifiers = try? PinnedItemsStore().loadPinnedIdentifiers() {
            cached = identifiers
        }
        readAt = Date()
        return cached
    }

    /// Called after this process changes a pin, so the next item vended
    /// reflects it rather than waiting out the cache.
    static func invalidate() {
        lock.lock()
        readAt = .distantPast
        lock.unlock()
    }
}
