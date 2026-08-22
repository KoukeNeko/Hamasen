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

@Suite("OpenSSHPrivateKey")
struct OpenSSHPrivateKeyTests {
    @Test("辨識未加密的 ed25519 金鑰")
    func parsesPlainEd25519() throws {
        let key = try OpenSSHPrivateKey.parse(SSHKeyFixtures.ed25519Plain)
        #expect(key.keyType == .ed25519)
        #expect(!key.isEncrypted)
    }

    @Test("辨識加密的 ed25519 金鑰")
    func parsesEncryptedEd25519() throws {
        let key = try OpenSSHPrivateKey.parse(SSHKeyFixtures.ed25519Encrypted)
        #expect(key.keyType == .ed25519)
        #expect(key.isEncrypted)
    }

    @Test("辨識 RSA 金鑰")
    func parsesRSA() throws {
        let key = try OpenSSHPrivateKey.parse(SSHKeyFixtures.rsaPlain)
        #expect(key.keyType == .rsa)
        #expect(!key.isEncrypted)
    }

    @Test("ECDSA 金鑰回報不支援並帶出型別名稱")
    func rejectsECDSAWithTypeName() {
        #expect(throws: OpenSSHPrivateKey.ParseError.unsupportedKeyType("ecdsa-sha2-nistp256")) {
            try OpenSSHPrivateKey.parse(SSHKeyFixtures.ecdsaPlain)
        }
    }

    @Test("舊式 PEM 金鑰回報需轉換格式")
    func rejectsLegacyPEM() {
        #expect(throws: OpenSSHPrivateKey.ParseError.legacyPEMFormat) {
            try OpenSSHPrivateKey.parse(SSHKeyFixtures.legacyPEM)
        }
    }

    @Test("非金鑰內容回報不是 OpenSSH 金鑰")
    func rejectsArbitraryText() {
        #expect(throws: OpenSSHPrivateKey.ParseError.notAnOpenSSHKey) {
            try OpenSSHPrivateKey.parse("just some text")
        }
    }

    @Test("內容毀損回報格式錯誤")
    func rejectsCorruptedBody() {
        let corrupted = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        bm90LXJlYWxseS1hLWtleQ==
        -----END OPENSSH PRIVATE KEY-----
        """
        #expect(throws: OpenSSHPrivateKey.ParseError.malformed) {
            try OpenSSHPrivateKey.parse(corrupted)
        }
    }

    @Test("前後空白不影響解析")
    func toleratesSurroundingWhitespace() throws {
        let padded = "\n  \n" + SSHKeyFixtures.ed25519Plain + "\n\n"
        let key = try OpenSSHPrivateKey.parse(padded)
        #expect(key.keyType == .ed25519)
    }
}
