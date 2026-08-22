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

/// The items the user asked to keep on this Mac.
///
/// Pinning is the counterweight to the cache allowance: without it, a limit
/// would eventually drop the one file someone needs on a plane. Both the app
/// and the File Provider extension read it, so it lives in the App Group
/// beside the mounted-server set.
public struct PinnedItemsStore: Sendable {
    private let fileURL: URL

    public init(appGroupIdentifier: String = SharedConstants.appGroupIdentifier) throws {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw ServerConfigStore.StoreError.appGroupContainerUnavailable(groupIdentifier: appGroupIdentifier)
        }
        self.fileURL = containerURL.appendingPathComponent(SharedConstants.pinnedItemsFileName)
    }

    /// Test initializer: uses an arbitrary file location.
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Item identifiers, as the File Provider spells them.
    public func loadPinnedIdentifiers() throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: fileURL))
    }

    public func savePinnedIdentifiers(_ identifiers: Set<String>) throws {
        try JSONEncoder().encode(identifiers).write(to: fileURL, options: .atomic)
    }

    /// Adds or removes one item and returns the resulting set, so a caller
    /// never has to read back what it just wrote.
    @discardableResult
    public func setPinned(_ isPinned: Bool, for identifier: String) throws -> Set<String> {
        var identifiers = try loadPinnedIdentifiers()
        if isPinned {
            identifiers.insert(identifier)
        } else {
            identifiers.remove(identifier)
        }
        try savePinnedIdentifiers(identifiers)
        return identifiers
    }

    /// Drops everything belonging to a server, for when it is unmounted or
    /// deleted and its identifiers can never match again.
    @discardableResult
    public func removePins(forServer serverID: UUID) throws -> Set<String> {
        let identifiers = try loadPinnedIdentifiers()
        let remaining = identifiers.filter { identifier in
            ItemIdentifierMapper.entity(for: .init(identifier))?.serverID != serverID
        }
        if remaining != identifiers {
            try savePinnedIdentifiers(remaining)
        }
        return remaining
    }
}
