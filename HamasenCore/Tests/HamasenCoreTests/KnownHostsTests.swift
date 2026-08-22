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

@Suite("KnownHosts")
struct KnownHostsTests {
    private static let endpoint = KnownHosts.endpoint(host: "files.example.com", port: 22)
    private static let fingerprint = "SHA256:AAAA"
    private static let otherFingerprint = "SHA256:BBBB"

    @Test("沒見過的端點視為首次信任")
    func trustsAnEndpointItHasNotSeen() {
        let hosts = KnownHosts()
        #expect(hosts.verdict(forEndpoint: Self.endpoint, fingerprint: Self.fingerprint) == .trustedOnFirstUse)
    }

    @Test("記錄後相同的金鑰視為未變更")
    func recognisesTheSameKey() {
        var hosts = KnownHosts()
        hosts.recordIfUnknown(Self.fingerprint, forEndpoint: Self.endpoint)
        #expect(hosts.verdict(forEndpoint: Self.endpoint, fingerprint: Self.fingerprint) == .unchanged)
    }

    /// The whole point: a key that is not the one recorded is refused, and
    /// what was expected is reported so the user can compare it.
    @Test("金鑰變更會被指出，並附上原本記錄的值")
    func reportsAChangedKey() {
        var hosts = KnownHosts()
        hosts.recordIfUnknown(Self.fingerprint, forEndpoint: Self.endpoint)
        #expect(
            hosts.verdict(forEndpoint: Self.endpoint, fingerprint: Self.otherFingerprint)
                == .changed(recorded: Self.fingerprint)
        )
    }

    /// Otherwise a man in the middle only has to be there twice.
    @Test("已記錄的端點不會被另一把金鑰覆寫")
    func neverOverwritesARecordedKey() {
        var hosts = KnownHosts()
        hosts.recordIfUnknown(Self.fingerprint, forEndpoint: Self.endpoint)
        hosts.recordIfUnknown(Self.otherFingerprint, forEndpoint: Self.endpoint)
        #expect(hosts.fingerprint(forEndpoint: Self.endpoint) == Self.fingerprint)
    }

    @Test("忘記端點後會重新首次信任")
    func forgettingLetsTheNextKeyThrough() {
        var hosts = KnownHosts()
        hosts.recordIfUnknown(Self.fingerprint, forEndpoint: Self.endpoint)
        hosts.forget(endpoint: Self.endpoint)
        #expect(hosts.verdict(forEndpoint: Self.endpoint, fingerprint: Self.otherFingerprint) == .trustedOnFirstUse)
    }

    @Test("同一台主機的不同連接埠各自記錄")
    func keepsPortsApart() {
        var hosts = KnownHosts()
        hosts.recordIfUnknown(Self.fingerprint, forEndpoint: KnownHosts.endpoint(host: "a.example.com", port: 22))
        #expect(
            hosts.verdict(
                forEndpoint: KnownHosts.endpoint(host: "a.example.com", port: 2222),
                fingerprint: Self.otherFingerprint
            ) == .trustedOnFirstUse
        )
    }

    @Test("主機名稱大小寫不同視為同一台")
    func treatsHostNamesCaseInsensitively() {
        #expect(
            KnownHosts.endpoint(host: "Files.Example.COM", port: 22)
                == KnownHosts.endpoint(host: "files.example.com", port: 22)
        )
    }

    @Test("ServerConfig 得出自己的端點")
    func derivesTheEndpointFromAServer() {
        let config = ServerConfig(name: "測試", host: "Files.Example.com", port: 2222, username: "u")
        #expect(config.hostKeyEndpoint == "files.example.com:2222")
    }
}
