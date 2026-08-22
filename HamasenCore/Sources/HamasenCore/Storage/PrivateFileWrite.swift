import Foundation

/// Writes a file only its owner can read.
///
/// A new file is created readable by every account on the Mac. That is fine
/// for most things and not for a backup: a plain one lists every server and
/// who signs in to them, and an encrypted one is an invitation to carry it
/// off and work on it at leisure.
public enum PrivateFileWrite {
    /// Owner read and write, and nothing for anybody else.
    public static let permissions: Int = 0o600

    public static func write(_ contents: Data, to url: URL) throws {
        try contents.write(to: url, options: .atomic)
        // After the write rather than before: an atomic write replaces the
        // file, and with it any permissions set on the old one.
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
    }
}
