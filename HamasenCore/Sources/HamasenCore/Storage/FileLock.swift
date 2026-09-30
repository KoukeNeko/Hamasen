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

/// An advisory lock on a file, held across processes.
///
/// The app and the File Provider extension both read-modify-write the same
/// files in the App Group, and an atomic write only keeps a reader from
/// seeing half a file: it does nothing for two writers that each read the
/// old contents. `flock` is released by the kernel when the process dies, so
/// a crashed holder cannot wedge the other side.
public struct FileLock: Sendable {
    public enum LockError: Error {
        case cannotOpen(path: String, code: Int32)
        case cannotLock(path: String, code: Int32)
    }

    private let lockURL: URL

    /// `lockURL` is a file of its own, never the data file: an atomic write
    /// replaces the data file's inode, and a lock on the old one would
    /// exclude nobody.
    public init(lockURL: URL) {
        self.lockURL = lockURL
    }

    /// Runs `body` while holding the lock exclusively, waiting for whoever
    /// holds it. Bodies are short reads and writes, never network calls.
    public func withLock<Result>(_ body: () throws -> Result) throws -> Result {
        // The lock can be asked for before anything else has made its
        // directory, as the first record of a store is.
        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw LockError.cannotOpen(path: lockURL.path, code: errno) }
        defer { close(descriptor) }

        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw LockError.cannotLock(path: lockURL.path, code: errno) }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}
