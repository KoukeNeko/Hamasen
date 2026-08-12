import Foundation
import Testing
@testable import HamasenCore

@Suite("ByteRangeAlignment")
struct ByteRangeAlignmentTests {
    private let blockSize = 4096

    @Test("起點向下對齊、終點向上對齊")
    func alignsBothEnds() {
        let range = ByteRangeAlignment.align(
            offset: 5000,
            length: 100,
            alignment: blockSize,
            fileSize: 1_000_000
        )
        #expect(range.offset == 4096)
        #expect(range.length == 4096)
    }

    @Test("已對齊的區間維持原樣")
    func keepsAlreadyAlignedRange() {
        let range = ByteRangeAlignment.align(
            offset: 8192,
            length: 8192,
            alignment: blockSize,
            fileSize: 1_000_000
        )
        #expect(range.offset == 8192)
        #expect(range.length == 8192)
    }

    @Test("檔尾的最後一段可以不足一個區塊")
    func allowsShortFinalChunk() {
        let range = ByteRangeAlignment.align(
            offset: 4096,
            length: 4096,
            alignment: blockSize,
            fileSize: 5000
        )
        #expect(range.offset == 4096)
        #expect(range.length == 904)
    }

    @Test("整個檔案小於一個區塊時只取檔案長度")
    func clampsSmallFile() {
        let range = ByteRangeAlignment.align(
            offset: 0,
            length: 10,
            alignment: blockSize,
            fileSize: 120
        )
        #expect(range.offset == 0)
        #expect(range.length == 120)
    }

    @Test("起點超過檔尾時回傳空區間")
    func returnsEmptyBeyondEndOfFile() {
        let range = ByteRangeAlignment.align(
            offset: 9000,
            length: 100,
            alignment: blockSize,
            fileSize: 5000
        )
        #expect(range.isEmpty)
    }

    @Test("零長度請求仍取回一個區塊")
    func expandsZeroLengthToOneBlock() {
        let range = ByteRangeAlignment.align(
            offset: 100,
            length: 0,
            alignment: blockSize,
            fileSize: 1_000_000
        )
        #expect(range.offset == 0)
        #expect(range.length == 4096)
    }

    @Test("對齊值為零或負數時不會當機")
    func toleratesInvalidAlignment() {
        let range = ByteRangeAlignment.align(
            offset: 10,
            length: 20,
            alignment: 0,
            fileSize: 1000
        )
        #expect(range.offset == 10)
        #expect(range.length == 20)
    }
}
