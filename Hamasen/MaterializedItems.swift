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

/// What the system currently holds a local copy of: the folders somebody has
/// opened and the files somebody has downloaded.
///
/// The eviction sweep asks what may be dropped; the change watcher asks what
/// is worth re-checking. One implementation because the enumeration has a
/// rule that is easy to get wrong in a second copy — the continuation resumes
/// exactly once, whichever way the enumeration ends.
enum MaterializedItems {
    /// Served as an enumerator, so it has to be drained page by page.
    static func all(
        from manager: NSFileProviderManager
    ) async throws -> [any NSFileProviderItemProtocol] {
        try await withCheckedThrowingContinuation { continuation in
            let collector = MaterializedItemCollector(continuation: continuation)
            collector.start(manager.enumeratorForMaterializedItems())
        }
    }
}

/// Collects one enumeration of the materialized set and resumes its
/// continuation exactly once, whichever way the enumeration ends.
nonisolated final class MaterializedItemCollector: NSObject, NSFileProviderEnumerationObserver, @unchecked Sendable {
    private let continuation: CheckedContinuation<[any NSFileProviderItemProtocol], Error>
    private var items: [any NSFileProviderItemProtocol] = []
    private var hasResumed = false
    /// Held because the enumerator is otherwise only referenced by the call
    /// that started it, and it has to outlive that call.
    private var enumerator: (any NSFileProviderEnumerator)?

    /// Nonisolated because the enumerator drives this from whatever queue it
    /// runs on; the protocol it conforms to is declared on the main actor,
    /// which would otherwise put every callback there.
    init(continuation: CheckedContinuation<[any NSFileProviderItemProtocol], Error>) {
        self.continuation = continuation
    }

    func start(_ enumerator: any NSFileProviderEnumerator) {
        self.enumerator = enumerator
        enumerator.enumerateItems(for: self, startingAt: NSFileProviderPage(Data()))
    }

    func didEnumerate(_ items: [any NSFileProviderItemProtocol]) {
        self.items.append(contentsOf: items)
    }

    func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
        if let nextPage {
            enumerator?.enumerateItems(for: self, startingAt: nextPage)
            return
        }
        finish { $0.resume(returning: items) }
    }

    func finishEnumeratingWithError(_ error: any Error) {
        finish { $0.resume(throwing: error) }
    }

    private func finish(
        _ resume: (CheckedContinuation<[any NSFileProviderItemProtocol], Error>) -> Void
    ) {
        guard !hasResumed else { return }
        hasResumed = true
        enumerator?.invalidate()
        enumerator = nil
        resume(continuation)
    }
}
