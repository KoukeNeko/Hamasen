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

/// One notification for everything a poll found.
///
/// A sync that touches twenty files is one event to the person watching, not
/// twenty. Sending one notification per file is how a feature like this gets
/// switched off within the hour, so a round of changes is collapsed into a
/// single line naming what is most likely to be looked for: the file, when
/// there is one, and otherwise the count.
public struct RemoteChangeSummary: Equatable, Sendable {
    public let serverName: String
    public let title: String
    public let message: String

    /// nil when nothing worth telling anyone about happened.
    public init?(serverName: String, changes: [RemoteDirectorySnapshot.Change]) {
        let real = changes.filter { !$0.isEmpty }
        guard !real.isEmpty else { return nil }

        let added = real.flatMap(\.addedNames)
        let updated = real.flatMap(\.updatedNames)
        let removed = real.flatMap(\.removedNames)
        let total = added.count + updated.count + removed.count

        self.serverName = serverName
        title = serverName

        // One file is named. Several are counted, because a list of twenty
        // names in a notification is a wall nobody reads, and the count is
        // what tells someone whether to go and look.
        if total == 1, let only = (added + updated + removed).first {
            if !added.isEmpty {
                message = String(localized: "新增了 \(only)", bundle: .module)
            } else if !updated.isEmpty {
                message = String(localized: "更新了 \(only)", bundle: .module)
            } else {
                message = String(localized: "刪除了 \(only)", bundle: .module)
            }
            return
        }

        var parts: [String] = []
        if !added.isEmpty {
            parts.append(String(localized: "新增 \(added.count) 個", bundle: .module))
        }
        if !updated.isEmpty {
            parts.append(String(localized: "更新 \(updated.count) 個", bundle: .module))
        }
        if !removed.isEmpty {
            parts.append(String(localized: "刪除 \(removed.count) 個", bundle: .module))
        }
        message = parts.formatted(.list(type: .and, width: .narrow))
    }
}
