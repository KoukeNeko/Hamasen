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

@Suite("FTPPassiveAddress")
struct FTPPassiveAddressTests {
    private static func reply(_ code: Int, _ text: String) -> FTPResponse {
        FTPResponse(code: code, lines: [text])
    }

    @Test("EPSV 只給連接埠，主機沿用控制連線")
    func readsExtendedPassive() {
        let address = FTPPassiveAddress.extendedPassive(
            from: Self.reply(229, "Entering Extended Passive Mode (|||49152|)")
        )
        #expect(address == FTPPassiveAddress(host: nil, port: 49152))
    }

    /// The delimiter is whatever character the server put first, not always
    /// a vertical bar.
    @Test("EPSV 的分隔字元由回應決定")
    func readsExtendedPassiveWithAnotherDelimiter() {
        let address = FTPPassiveAddress.extendedPassive(
            from: Self.reply(229, "Entering Extended Passive Mode (!!!1234!)")
        )
        #expect(address?.port == 1234)
    }

    @Test("PASV 的六個數字組成位址與連接埠")
    func readsPassive() {
        let address = FTPPassiveAddress.passive(
            from: Self.reply(227, "Entering Passive Mode (10,0,0,1,192,0)")
        )
        #expect(address == FTPPassiveAddress(host: "10.0.0.1", port: 49152))
    }

    /// Some servers print the address twice; the one in brackets is the one
    /// that counts, and it is the last.
    @Test("回應裡有多組括號時取最後一組")
    func readsTheBracketedAddress() {
        let address = FTPPassiveAddress.passive(
            from: Self.reply(227, "PASV ok (see docs) (127,0,0,1,4,1)")
        )
        #expect(address == FTPPassiveAddress(host: "127.0.0.1", port: 1025))
    }

    @Test("數字超出範圍或數量不對時讀不出位址")
    func rejectsMalformedPassiveReplies() {
        #expect(FTPPassiveAddress.passive(from: Self.reply(227, "(10,0,0,1,192)")) == nil)
        #expect(FTPPassiveAddress.passive(from: Self.reply(227, "(10,0,0,300,192,0)")) == nil)
        #expect(FTPPassiveAddress.passive(from: Self.reply(227, "no brackets here")) == nil)
        #expect(FTPPassiveAddress.extendedPassive(from: Self.reply(229, "(|||0|)")) == nil)
    }
}
