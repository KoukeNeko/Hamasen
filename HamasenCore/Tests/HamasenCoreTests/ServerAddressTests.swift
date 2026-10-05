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

@Suite("ServerAddress")
struct ServerAddressTests {
    @Test("貼上網址時去掉前後空白與換行")
    func trimsPastedText() {
        #expect(ServerAddress.parse("  nas.local \n") == ServerAddress(host: "nas.local"))
    }

    @Test("完整網址拆成協定、主機、連接埠與路徑")
    func readsWholeURLs() {
        #expect(ServerAddress.parse("https://nas.local:5006/dav/家用")
            == ServerAddress(scheme: "https", host: "nas.local", port: 5006, path: "/dav/家用"))
        #expect(ServerAddress.parse("smb://192.168.1.20/Public")
            == ServerAddress(scheme: "smb", host: "192.168.1.20", path: "/Public"))
    }

    @Test("主機加連接埠")
    func readsHostAndPort() {
        #expect(ServerAddress.parse("192.168.1.20:2222") == ServerAddress(host: "192.168.1.20", port: 2222))
    }

    @Test("沒有主機時不接受")
    func rejectsEmptyInput() {
        #expect(ServerAddress.parse("   ") == nil)
        #expect(ServerAddress.parse("https://") == nil)
    }

    @Test("WebDAV 網址省略預設連接埠")
    func composesWebDAVURLs() {
        let config = ServerConfig(
            name: "NAS", transferProtocol: .webdavs, host: "nas.local", port: 5006, username: "u",
            remotePath: "/dav")
        #expect(ServerAddress.webDAVURL(for: config) == "https://nas.local:5006/dav")
        var plain = config
        plain.transferProtocol = .webdav
        plain.port = 80
        plain.remotePath = "/"
        #expect(ServerAddress.webDAVURL(for: plain) == "http://nas.local")
    }
}
