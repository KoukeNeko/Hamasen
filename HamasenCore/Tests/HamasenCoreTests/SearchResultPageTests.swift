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
import Testing
@testable import HamasenCore

@Suite("SearchResultPage")
struct SearchResultPageTests {
    /// Exceeding the cap terminates the extension process, so this is the
    /// property that matters more than any other here.
    @Test(arguments: [0, 1, 3, 7, 10, 11, 99])
    func neverHandsBackMoreThanTheCap(offset: Int) {
        for cap in [1, 2, 5, 10] {
            let page = SearchResultPage(resultCount: 10, offset: offset, maximumPerPage: cap)
            #expect(page.range.count <= cap, "offset \(offset), cap \(cap)")
        }
    }

    @Test
    func walksTheWholeListExactlyOnce() {
        var seen: [Int] = []
        var offset: Int? = 0
        var rounds = 0
        while let start = offset, rounds < 20 {
            let page = SearchResultPage(resultCount: 7, offset: start, maximumPerPage: 3)
            seen += Array(page.range)
            offset = page.nextOffset
            rounds += 1
        }
        #expect(seen == Array(0..<7))
        #expect(rounds == 3)
    }

    @Test
    func theLastPageNamesNoNext() {
        #expect(SearchResultPage(resultCount: 6, offset: 3, maximumPerPage: 3).nextOffset == nil)
        #expect(SearchResultPage(resultCount: 7, offset: 3, maximumPerPage: 3).nextOffset == 6)
    }

    @Test
    func noResultsIsOneEmptyFinalPage() {
        let page = SearchResultPage(resultCount: 0, offset: 0, maximumPerPage: 50)
        #expect(page.isEmpty)
        #expect(page.nextOffset == nil)
    }

    /// An offset past the end finishes rather than reading off the end.
    @Test
    func anOffsetPastTheEndIsEmpty() {
        let page = SearchResultPage(resultCount: 4, offset: 40, maximumPerPage: 5)
        #expect(page.isEmpty)
        #expect(page.nextOffset == nil)
    }

    /// A cap of zero would make no page deliverable and the enumeration never
    /// finish, which reads to the user as a search that hangs.
    @Test
    func aCapOfZeroStillDeliversSomething() {
        let page = SearchResultPage(resultCount: 3, offset: 0, maximumPerPage: 0)
        #expect(page.range == 0..<1)
    }

    @Test
    func theTokenSurvivesARoundTrip() {
        for offset in [0, 1, 500, 123_456] {
            #expect(SearchResultPage.offset(from: SearchResultPage.token(for: offset)) == offset)
        }
        #expect(SearchResultPage.token(for: 123_456).count < 500)
    }

    /// Repeating a page is visible to the user; silently skipping results is
    /// not, so an unreadable token starts over.
    @Test
    func anUnreadableTokenStartsOver() {
        #expect(SearchResultPage.offset(from: Data("not a number".utf8)) == 0)
        #expect(SearchResultPage.offset(from: Data()) == 0)
    }
}
