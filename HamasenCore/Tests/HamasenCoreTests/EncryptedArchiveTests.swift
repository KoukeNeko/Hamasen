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

@Suite("EncryptedArchive")
struct EncryptedArchiveTests {
    private static let payload = Data("the servers and their passwords".utf8)

    @Test("用同一個密碼可以還原內容")
    func roundTripsWithTheSamePassphrase() throws {
        let sealed = try EncryptedArchive.seal(Self.payload, passphrase: "correct horse")
        #expect(try sealed.opened(passphrase: "correct horse") == Self.payload)
    }

    @Test("密碼錯誤時打不開")
    func refusesTheWrongPassphrase() throws {
        let sealed = try EncryptedArchive.seal(Self.payload, passphrase: "correct horse")
        #expect(throws: EncryptedArchive.ArchiveError.wrongPassphraseOrDamaged) {
            try sealed.opened(passphrase: "wrong horse")
        }
    }

    /// Authenticated encryption: a file edited in transit must fail to open
    /// rather than decrypt into something else.
    @Test("內容被竄改時打不開")
    func refusesATamperedPayload() throws {
        let sealed = try EncryptedArchive.seal(Self.payload, passphrase: "correct horse")
        var damaged = sealed.sealed
        damaged[damaged.count / 2] ^= 0xFF
        let tampered = EncryptedArchive(
            keyDerivation: sealed.keyDerivation,
            iterations: sealed.iterations,
            salt: sealed.salt,
            cipher: sealed.cipher,
            sealed: damaged
        )

        #expect(throws: EncryptedArchive.ArchiveError.wrongPassphraseOrDamaged) {
            try tampered.opened(passphrase: "correct horse")
        }
    }

    /// Two exports of the same thing under the same passphrase must not look
    /// alike, or the file itself would say when nothing changed.
    @Test("同樣的內容與密碼，兩次封裝的結果不同")
    func sealsDifferentlyEveryTime() throws {
        let first = try EncryptedArchive.seal(Self.payload, passphrase: "correct horse")
        let second = try EncryptedArchive.seal(Self.payload, passphrase: "correct horse")

        #expect(first.salt != second.salt)
        #expect(first.sealed != second.sealed)
    }

    @Test("不認得的加密方式會被拒絕，而不是硬解")
    func refusesAnAlgorithmItDoesNotKnow() throws {
        let sealed = try EncryptedArchive.seal(Self.payload, passphrase: "correct horse")
        let foreign = EncryptedArchive(
            keyDerivation: "scrypt",
            iterations: sealed.iterations,
            salt: sealed.salt,
            cipher: sealed.cipher,
            sealed: sealed.sealed
        )

        #expect(throws: EncryptedArchive.ArchiveError.unsupportedFormat) {
            try foreign.opened(passphrase: "correct horse")
        }
    }

    /// The parameters travel with the file so a reader uses what was used,
    /// not what it would choose today.
    @Test("解封時採用檔案裡記錄的參數")
    func readsTheParametersFromTheFile() throws {
        let weaker = 1_000
        let salt = Data(repeating: 7, count: 16)
        let key = try #require(
            try? EncryptedArchive.seal(Self.payload, passphrase: "p")
        )
        _ = key

        // Sealed by hand at a different work factor than the current default.
        let sealed = try EncryptedArchive.sealForTesting(
            Self.payload, passphrase: "p", salt: salt, iterations: weaker
        )
        #expect(sealed.iterations == weaker)
        #expect(try sealed.opened(passphrase: "p") == Self.payload)
    }

    @Test("明文不會出現在封裝後的位元組裡")
    func leavesNoPlaintextBehind() throws {
        let sealed = try EncryptedArchive.seal(Self.payload, passphrase: "correct horse")
        #expect(sealed.sealed.range(of: Self.payload) == nil)
    }
}

@Suite("EncryptedArchive work factor")
struct EncryptedArchiveWorkFactorTests {
    /// The protection a passphrase gets is the cost of guessing it, so the
    /// derivation has to actually be slow. A misused CommonCrypto call can
    /// return success having done far less work than it was asked for, and
    /// nothing else here would notice.
    @Test("推導一把金鑰的成本符合設定的迭代次數")
    func derivationCostsWhatItShould() throws {
        let started = Date()
        _ = try EncryptedArchive.seal(Data("payload".utf8), passphrase: "correct horse")
        let elapsed = Date().timeIntervalSince(started)

        // Generous, because it runs on whatever machine happens to be
        // building: the point is to catch a derivation that did nothing, not
        // to measure the hardware.
        #expect(elapsed > 0.05, "600,000 iterations finished in \(elapsed)s, which is too fast to have run")
    }

    @Test("空密碼會被拒絕")
    func refusesAnEmptyPassphrase() {
        #expect(throws: EncryptedArchive.ArchiveError.emptyPassphrase) {
            try EncryptedArchive.seal(Data("payload".utf8), passphrase: "")
        }
    }
}
