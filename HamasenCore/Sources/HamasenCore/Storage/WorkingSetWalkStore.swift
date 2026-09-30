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

/// Keeps the walk between the pages the system asks for.
///
/// The extension has no memory of its own between calls, and the page token
/// the system hands back holds 500 bytes — enough to say which walk and which
/// step, not enough for the queue. The queue is here.
public struct WorkingSetWalkStore: Sendable {
    private let fileURL: URL

    public init(appGroupIdentifier: String = SharedConstants.appGroupIdentifier) throws {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw ServerConfigStore.StoreError.appGroupContainerUnavailable(groupIdentifier: appGroupIdentifier)
        }
        self.fileURL = containerURL.appendingPathComponent(SharedConstants.workingSetWalkFileName)
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() -> WorkingSetWalk? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(WorkingSetWalk.self, from: data)
    }

    public func save(_ walk: WorkingSetWalk) throws {
        try JSONEncoder().encode(walk).write(to: fileURL, options: .atomic)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Whether the working set should be enumerated from the first page
    /// again. True with no walk on file at all, which is how a domain that
    /// predates the walk, or one whose settings were just changed, gets one.
    public func isWalkDue(at now: Date = Date()) -> Bool {
        guard let walk = load() else { return true }
        return walk.isStale(at: now)
    }

    /// The walk a page token refers to, or a fresh one when the token names a
    /// walk that is gone or a step this one has passed.
    ///
    /// A fresh walk repeats work; resuming the wrong one would skip
    /// directories, and nothing would ever say so.
    public func walk(for token: WorkingSetWalk.Token?, serverIDs: [UUID], limits: WorkingSetWalk.Limits) -> WorkingSetWalk {
        if let token, let stored = load(), stored.matches(token) {
            return stored
        }
        return WorkingSetWalk(serverIDs: serverIDs, limits: limits)
    }

    /// The walk the next change batch should take a step of: the one the
    /// anchor's token names while it is unfinished, else a new one if a walk
    /// is due, else none.
    public func walkForChangeBatch(
        after token: WorkingSetWalk.Token?,
        serverIDs: [UUID],
        limits: WorkingSetWalk.Limits,
        at now: Date = Date()
    ) -> WorkingSetWalk? {
        // Resumed only under the settings it was started with. A walk saved
        // by a step still running when the settings changed would otherwise
        // come back and keep listing a server that opted out.
        if let token, let stored = load(), stored.belongs(to: token), stored.completedAt == nil, !stored.isFinished,
           stored.limits == limits, Set(stored.serverIDs) == Set(serverIDs) {
            return stored
        }
        guard isWalkDue(at: now) else { return nil }
        return WorkingSetWalk(serverIDs: serverIDs, limits: limits, startedAt: now)
    }
}
