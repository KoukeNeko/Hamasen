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
import UniformTypeIdentifiers

/// One hit, described the way the system asks for it.
///
/// The identifier has to be the same one every other call uses, or opening a
/// result would address something the provider does not recognise.
@available(macOS 26, *)
final class RemoteSearchResult: NSObject, NSFileProviderSearchResult {
    private let serverID: UUID
    private let remoteItem: RemoteItem

    init(serverID: UUID, remoteItem: RemoteItem) {
        self.serverID = serverID
        self.remoteItem = remoteItem
    }

    var itemIdentifier: NSFileProviderItemIdentifier {
        ItemIdentifierMapper.identifier(for: .item(serverID: serverID, path: remoteItem.path))
    }

    var filename: String { remoteItem.name }
    var creationDate: Date? { remoteItem.creationDate }
    var contentModificationDate: Date? { remoteItem.modificationDate }
    /// Nothing here records when a file was last opened, and inventing a date
    /// would order the results by a fact that does not exist.
    var lastUsedDate: Date? { nil }
    var documentSize: NSNumber? { NSNumber(value: remoteItem.size) }

    var contentType: UTType {
        switch remoteItem.kind {
        case .directory: return .folder
        case .symlink: return .symbolicLink
        case .file:
            let fileExtension = (remoteItem.name as NSString).pathExtension
            return UTType(filenameExtension: fileExtension) ?? .data
        }
    }
}

/// Answers one search, across every mounted server.
///
/// The system makes a new one of these per query and calls `invalidate()` on
/// the last when the user types another character, which is why cancelling
/// matters more here than finishing quickly: without it there would be one
/// walk in flight per keystroke.
@available(macOS 26, *)
final class RemoteSearchEnumerator: NSObject, NSFileProviderSearchEnumerator {
    /// A hint, not a limit — but a search with no ceiling of its own would
    /// walk a whole tree for a query the user has already replaced.
    private static let resultCeiling = 500

    private let request: NSFileProviderStringSearchRequest
    private let registry: ConnectionRegistry

    private let lock = NSLock()
    private var search: Task<Void, Never>?
    /// Collected once and then paged out. Re-running the search for page two
    /// would give a different answer from page one.
    private var results: [RemoteSearchResult] = []

    init(request: NSFileProviderStringSearchRequest, registry: ConnectionRegistry) {
        self.request = request
        self.registry = registry
    }

    func invalidate() {
        lock.lock()
        let running = search
        search = nil
        lock.unlock()
        running?.cancel()
    }

    func enumerateSearchResults(
        for observer: any NSFileProviderSearchEnumerationObserver,
        startingAt page: NSFileProviderPage?
    ) {
        if let page {
            deliver(from: SearchResultPage.offset(from: page.rawValue), to: observer)
            return
        }

        let query = request.query
        let limit = min(max(request.desiredNumberOfResults, 1), Self.resultCeiling)
        let registry = registry

        let task = Task { [weak self] in
            var collected: [RemoteSearchResult] = []
            defer {
                FileProviderExtension.log.notice(
                    "Search \"\(query)\" collected \(collected.count) result(s)")
            }
            do {
                for config in try ConnectionRegistry.mountedConfigs() {
                    if collected.count >= limit { break }
                    try Task.checkCancellation()
                    // One unreachable server must not empty the results: the
                    // others are still searchable, and a query that answered
                    // nothing would look like a query that matched nothing.
                    guard let service = try? await registry.service(for: config.id),
                          let found = try? await service.searchItems(
                              matching: query, under: RemotePath.root,
                              limit: limit - collected.count)
                    else { continue }
                    collected += found.map {
                        RemoteSearchResult(serverID: config.id, remoteItem: $0)
                    }
                }
            } catch {
                observer.finishEnumeratingWithError(FileProviderErrorMapper.map(error))
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.lock.lock()
            self.results = collected
            self.lock.unlock()
            self.deliver(from: 0, to: observer)
        }

        lock.lock()
        search = task
        lock.unlock()
    }

    private func deliver(
        from offset: Int, to observer: any NSFileProviderSearchEnumerationObserver
    ) {
        lock.lock()
        let all = results
        lock.unlock()

        let page = SearchResultPage(
            resultCount: all.count, offset: offset,
            maximumPerPage: observer.maximumNumberOfResultsPerPage)
        if !page.isEmpty {
            observer.didEnumerate(Array(all[page.range]))
        }
        observer.finishEnumerating(
            upTo: page.nextOffset.map { NSFileProviderPage(SearchResultPage.token(for: $0)) })
    }
}

/// Declared on macOS 26, where the system first had somewhere to put the
/// results. Below it, Spotlight indexes only what has been downloaded, which
/// it does without being asked.
@available(macOS 26, *)
extension FileProviderExtension: NSFileProviderSearching {
    func searchEnumerator(
        for request: NSFileProviderStringSearchRequest
    ) -> any NSFileProviderSearchEnumerator {
        Self.log.notice("Search requested: \"\(request.query)\" (\(request.desiredNumberOfResults) wanted)")
        return RemoteSearchEnumerator(request: request, registry: searchRegistry)
    }
}
