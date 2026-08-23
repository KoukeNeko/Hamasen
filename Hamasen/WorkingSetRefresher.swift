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

/// Gives the extension its chances to start a walk.
///
/// The system asks the extension for the working set's first page once,
/// when the domain is created, and after that only for changes, and only
/// when signalled. The extension knows when a walk is due but has no timer
/// to notice it with, so the signals come from here: on a schedule, and
/// when the indexing settings change. Launch is covered by the domain
/// registration, which signals on its own.
@MainActor
final class WorkingSetRefresher {
    /// Often enough that a walk which came due overnight starts in the
    /// morning; rare enough that the extension is not launched for nothing.
    private static let checkInterval: Duration = .seconds(60 * 60)

    private var schedule: Task<Void, Never>?

    func start() {
        guard schedule == nil else { return }
        schedule = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.checkInterval)
                guard !Task.isCancelled else { return }
                await Self.signal()
            }
        }
    }

    /// The next walk starts over under the new settings instead of waiting
    /// out the old walk's day.
    func settingsChanged() {
        (try? WorkingSetWalkStore())?.clear()
        Task { await Self.signal() }
    }

    private static func signal() async {
        // No domain means nothing is mounted, and nothing to walk.
        _ = try? await FinderDomain.signalWorkingSet()
    }
}
