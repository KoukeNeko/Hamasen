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

@Suite("Finder appearance")
struct FinderAppearanceTests {
    /// What Finder's Customize Folder wrote to `_kMDItemUserTags` for red on
    /// macOS 26: the provider's tag has to be the same tag, not a lookalike.
    @Test("顏色標籤和 Finder 自己寫的位元組相同")
    func tagMatchesWhatFinderWrites() throws {
        let finderBytes = Data(
            hexadecimal: "62706c6973743030a101555265640a36080a0000000000000101000000000000000200000000000000000000000000000010")
        #expect(FinderAppearance(color: .red).tagData == finderBytes)
        #expect(FinderAppearance().tagData == nil)
    }

    @Test("符號和 emoji 寫成 Finder 讀的 JSON")
    func iconAttributeIsFindersJSON() throws {
        let symbol = try #require(FinderAppearance(icon: .symbol("person.fill")).iconAttribute)
        #expect(String(decoding: symbol, as: UTF8.self) == #"{"sym":"person.fill"}"#)
        let emoji = try #require(FinderAppearance(icon: .emoji("😊")).iconAttribute)
        #expect(String(decoding: emoji, as: UTF8.self) == #"{"emoji":"😊"}"#)
        #expect(FinderAppearance().iconAttribute == nil)
    }

    @Test("沒有自訂的資料夾保留原本的版本")
    func defaultLeavesTheItemTokenAlone() {
        var config = ServerConfig(name: "nas", host: "nas.local", username: "kai")
        let plain = config.finderItemToken
        #expect(plain == "nas|\(config.storageMode.versionToken)")
        config.finderAppearance.color = .blue
        #expect(config.finderItemToken != plain)
    }

    @Test("Finder 名稱留白時沿用連線名稱")
    func blankFinderNameFallsBack() {
        var config = ServerConfig(name: "nas", host: "nas.local", username: "kai")
        config.finderAppearance.name = "  "
        #expect(config.finderFolderName == "nas")
        config.finderAppearance.name = "Home NAS"
        #expect(config.finderFolderName == "Home NAS")
    }

    @Test("外觀能存回讀出，讀不懂時退回預設而不丟掉連線")
    func appearanceRoundTripsAndToleratesGarbage() throws {
        var config = ServerConfig(name: "nas", host: "nas.local", username: "kai")
        config.finderAppearance = FinderAppearance(name: "NAS", color: .green, icon: .emoji("🖥"))
        let data = try JSONEncoder().encode(config)
        #expect(String(decoding: data, as: UTF8.self).contains(#""icon":{"emoji":"🖥"}"#))
        #expect(try JSONDecoder().decode(ServerConfig.self, from: data) == config)

        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["finderAppearance"] = ["icon": ["emoji": ["_0": "🖥"]]]
        let garbled = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ServerConfig.self, from: garbled)
        #expect(decoded.finderAppearance == FinderAppearance())
        #expect(decoded.name == "nas")
    }
}

private extension Data {
    init(hexadecimal: String) {
        var bytes: [UInt8] = []
        var index = hexadecimal.startIndex
        while index < hexadecimal.endIndex {
            let next = hexadecimal.index(index, offsetBy: 2)
            bytes.append(UInt8(hexadecimal[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}
