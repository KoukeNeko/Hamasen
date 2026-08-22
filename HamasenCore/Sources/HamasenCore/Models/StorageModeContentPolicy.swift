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

extension ServerConfig.StorageMode {
    /// How the system should treat the content of items in this server's
    /// folder.
    ///
    /// `.inherited` on a server folder means the domain root's policy applies,
    /// which on macOS keeps content until the disk is under pressure. Online
    /// only asks for the opposite bias: fetch on read, and drop the copy as
    /// soon as the server's version moves on. Items inside a server folder
    /// always inherit, so one value covers a whole server.
    public var contentPolicy: NSFileProviderContentPolicy {
        switch self {
        case .automatic:
            return .inherited
        case .onlineOnly:
            return .downloadLazilyAndEvictOnRemoteUpdate
        }
    }

    /// Distinguishes the modes inside an item version, so that changing the
    /// mode reaches the system: without it a server folder looks unchanged
    /// and the old policy stays in force until something else re-enumerates.
    public var versionToken: String {
        rawValue
    }
}

extension ServerConfig {
    /// Everything about a server that its Finder folder shows or obeys.
    ///
    /// The change tracker compares these to decide what to report, and the
    /// folder's item version is built from the same string: announcing a
    /// change the item does not reflect, or changing an item nobody is told
    /// about, both leave Finder on stale metadata.
    public var finderItemToken: String {
        "\(name)|\(storageMode.versionToken)"
    }
}
