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

/// Which results go in one page, and where the next one starts.
///
/// The cap is not advisory. The File Provider header states that handing back
/// more than `maximumNumberOfResultsPerPage` in a single page terminates the
/// extension process — not an error, the process. The arithmetic therefore
/// lives here, where it can be tested, rather than inline in an enumerator
/// that no test can reach.
public struct SearchResultPage: Equatable, Sendable {
    /// The slice to deliver. Empty when the offset is at or past the end.
    public let range: Range<Int>
    /// Where the system should resume, or nil when this page is the last.
    public let nextOffset: Int?

    public init(resultCount: Int, offset: Int, maximumPerPage: Int) {
        // A cap of zero or less would make no page ever deliverable and the
        // enumeration never finish, so one result is the floor.
        let cap = max(maximumPerPage, 1)
        let start = min(max(offset, 0), resultCount)
        let end = min(start + cap, resultCount)
        range = start..<end
        nextOffset = end < resultCount ? end : nil
    }

    public var isEmpty: Bool { range.isEmpty }

    /// The page token, which the header limits to 500 bytes. An offset spends
    /// a handful.
    public static func token(for offset: Int) -> Data {
        Data(String(offset).utf8)
    }

    /// A token that cannot be read starts the enumeration over rather than
    /// skipping results: repeating a page is visible, losing one is not.
    public static func offset(from token: Data) -> Int {
        Int(String(decoding: token, as: UTF8.self)) ?? 0
    }
}
