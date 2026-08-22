import Foundation
import Testing
@testable import HamasenCore

@Suite("PrivateFileWrite")
struct PrivateFileWriteTests {
    private static func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("private-write-\(UUID().uuidString)")
    }

    private static func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }

    @Test("寫出的檔案只有擁有者讀得到")
    func writesAFileOnlyItsOwnerCanRead() throws {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try PrivateFileWrite.write(Data("secret".utf8), to: url)

        #expect(try Self.permissions(of: url) == 0o600)
        #expect(try Data(contentsOf: url) == Data("secret".utf8))
    }

    /// An atomic write replaces the file, taking the old one's permissions
    /// with it, so a second write has to set them again.
    @Test("覆寫既有檔案後權限仍然正確")
    func keepsThePermissionsWhenOverwriting() throws {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try PrivateFileWrite.write(Data("first".utf8), to: url)
        try PrivateFileWrite.write(Data("second".utf8), to: url)

        #expect(try Self.permissions(of: url) == 0o600)
        #expect(try Data(contentsOf: url) == Data("second".utf8))
    }

    /// The default a plain write gets, which is what this exists to avoid.
    @Test("一般寫入的權限確實比較寬鬆")
    func isStricterThanAnOrdinaryWrite() throws {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try Data("secret".utf8).write(to: url, options: .atomic)
        let ordinary = try Self.permissions(of: url)

        #expect(ordinary != 0o600, "一般寫入就已經是 0600，這個型別就沒有存在的必要")
        #expect(ordinary & 0o077 != 0, "一般寫入沒有給其他人權限，前提不成立")
    }
}
