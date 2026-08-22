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

@Suite("FTPResponseAccumulator")
struct FTPResponseAccumulatorTests {
    private static func responses(from lines: [String]) -> [FTPResponse] {
        var accumulator = FTPResponseAccumulator()
        return lines.compactMap { accumulator.accept($0) }
    }

    @Test("單行回應立刻完成")
    func completesASingleLineReply() {
        let replies = Self.responses(from: ["220 Service ready\r\n"])
        #expect(replies == [FTPResponse(code: 220, lines: ["Service ready"])])
    }

    @Test("多行回應要等到相同代碼加空格才結束")
    func waitsForTheClosingLine() {
        let replies = Self.responses(from: [
            "220-Welcome",
            "220-Be nice",
            "220 Ready",
        ])
        #expect(replies == [FTPResponse(code: 220, lines: ["Welcome", "Be nice", "Ready"])])
    }

    /// The classic way a naive reader ends a reply early: text inside it
    /// happens to look like a completion line for another code.
    @Test("回應內容裡出現別的代碼不會提早結束")
    func doesNotEndOnACodeFromInsideTheText() {
        let replies = Self.responses(from: [
            "220-Notes follow",
            "230 This looks like a reply but is not",
            "220 Ready",
        ])
        #expect(replies.count == 1)
        #expect(replies.first?.code == 220)
        #expect(replies.first?.lines.count == 3)
    }

    @Test("沒有代碼開頭的續行也會被收進來")
    func keepsContinuationLinesWithoutACode() {
        let replies = Self.responses(from: ["211-Status", " no code here", "211 End"])
        #expect(replies.first?.lines == ["Status", " no code here", "End"])
    }

    @Test("代碼的類別分得出來")
    func classifiesReplyCodes() {
        #expect(FTPResponse(code: 150, lines: []).isPositivePreliminary)
        #expect(FTPResponse(code: 226, lines: []).isPositiveCompletion)
        #expect(FTPResponse(code: 331, lines: []).isPositiveIntermediate)
        #expect(FTPResponse(code: 425, lines: []).isTransientFailure)
        #expect(FTPResponse(code: 550, lines: []).isPermanentFailure)
        #expect(FTPResponse(code: 550, lines: []).isFailure)
    }
}

@Suite("FTPListing")
struct FTPListingTests {
    private static let referenceDate = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01-01 UTC

    // MARK: - MLSD

    @Test("MLSD 讀出型別、大小與時間")
    func readsMachineListing() {
        let body = """
        type=file;size=1234;modify=20251224093000; report.pdf
        type=dir;modify=20251101000000; archive
        """
        let items = FTPListing.parseMachineListing(body, directory: "/docs")

        #expect(items.count == 2)
        #expect(items[0].path == "/docs/report.pdf")
        #expect(items[0].kind == .file)
        #expect(items[0].size == 1234)
        #expect(items[1].kind == .directory)
        #expect(items[1].name == "archive")
    }

    @Test("MLSD 略過目錄自身與上層")
    func skipsTheDirectoryItself() {
        let body = """
        type=cdir;modify=20251101000000; .
        type=pdir;modify=20251101000000; ..
        type=file;size=1; keep.txt
        """
        #expect(FTPListing.parseMachineListing(body, directory: "/").map(\.name) == ["keep.txt"])
    }

    @Test("MLSD 的檔名可以有空白")
    func keepsSpacesInMachineListedNames() {
        let items = FTPListing.parseMachineListing("type=file;size=2; my report.pdf", directory: "/")
        #expect(items.first?.name == "my report.pdf")
    }

    // MARK: - LIST

    @Test("Unix 清單讀出型別、大小與名稱")
    func readsUnixListing() {
        let body = """
        -rw-r--r--   1 owner group        1234 Dec 24 09:30 report.pdf
        drwxr-xr-x   2 owner group        4096 Nov  1 2025 archive
        """
        let items = FTPListing.parseUnixListing(body, directory: "/docs", referenceDate: Self.referenceDate)

        #expect(items.count == 2)
        #expect(items[0].kind == .file)
        #expect(items[0].size == 1234)
        #expect(items[0].path == "/docs/report.pdf")
        #expect(items[1].kind == .directory)
        #expect(items[1].name == "archive")
    }

    /// Splitting the whole line on spaces would lose everything after the
    /// first one in the name.
    @Test("Unix 清單的檔名可以有空白")
    func keepsSpacesInUnixListedNames() {
        let body = "-rw-r--r--   1 owner group  12 Dec 24 09:30 my long report.pdf"
        let items = FTPListing.parseUnixListing(body, directory: "/", referenceDate: Self.referenceDate)
        #expect(items.first?.name == "my long report.pdf")
    }

    @Test("符號連結只取連結本身的名稱")
    func readsTheLinkRatherThanItsTarget() {
        let body = "lrwxrwxrwx   1 owner group   7 Dec 24 09:30 current -> release-4"
        let items = FTPListing.parseUnixListing(body, directory: "/", referenceDate: Self.referenceDate)
        #expect(items.first?.kind == .symlink)
        #expect(items.first?.name == "current")
    }

    /// `ls` prints a time instead of a year for recent entries, so December
    /// read in January belongs to the year before.
    @Test("只有時間沒有年份時，未來的日期算前一年")
    func readsARecentDateAsLastYear() throws {
        let body = "-rw-r--r--   1 owner group  12 Dec 24 09:30 report.pdf"
        let items = FTPListing.parseUnixListing(body, directory: "/", referenceDate: Self.referenceDate)
        let modified = try #require(items.first?.modificationDate)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        #expect(calendar.component(.year, from: modified) == 2025)
        #expect(calendar.component(.month, from: modified) == 12)
    }

    @Test("有年份時直接採用")
    func readsAnExplicitYear() throws {
        let body = "-rw-r--r--   1 owner group  12 Nov  1 2023 old.txt"
        let items = FTPListing.parseUnixListing(body, directory: "/", referenceDate: Self.referenceDate)
        let modified = try #require(items.first?.modificationDate)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        #expect(calendar.component(.year, from: modified) == 2023)
    }

    @Test("讀不懂的行被略過而不是變成壞項目")
    func skipsLinesItCannotRead() {
        let body = """
        total 12
        -rw-r--r--   1 owner group  12 Dec 24 09:30 good.txt
        garbage
        """
        let items = FTPListing.parseUnixListing(body, directory: "/", referenceDate: Self.referenceDate)
        #expect(items.map(\.name) == ["good.txt"])
    }
}
