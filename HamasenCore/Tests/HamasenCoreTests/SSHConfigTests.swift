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

import Testing
@testable import HamasenCore

@Suite("SSH config")
struct SSHConfigTests {
    @Test("每個具名主機各自取得連線欄位")
    func readsEachNamedHost() {
        let text = """
        # Work machines
        Host nas
            HostName 192.168.1.20
            Port 2222
            User admin
            IdentityFile ~/.ssh/id_nas

        Host web
          HostName=web.example.com
          User = deploy
        """
        let hosts = SSHConfig.hosts(in: text)
        #expect(hosts == [
            SSHConfigHost(alias: "nas", hostName: "192.168.1.20", port: 2222, user: "admin", identityFile: "~/.ssh/id_nas"),
            SSHConfigHost(alias: "web", hostName: "web.example.com", port: nil, user: "deploy", identityFile: nil),
        ])
    }

    @Test("第一個取得的值為準，萬用字元區塊套用到符合的主機")
    func firstValueWinsAndPatternsApply() {
        let text = """
        Host nas
            User admin

        Host *.lan nas
            User fallback
            Port 2200

        Host *
            IdentityFile ~/.ssh/id_ed25519
            Port 22
        """
        let hosts = SSHConfig.hosts(in: text)
        #expect(hosts == [
            SSHConfigHost(alias: "nas", hostName: nil, port: 2200, user: "admin", identityFile: "~/.ssh/id_ed25519"),
        ])
    }

    @Test("排除的樣式、Match 區塊和萬用字元別名不會成為主機")
    func skipsNegationsMatchBlocksAndPatterns() {
        let text = """
        Host * !bastion
            User everyone

        Host bastion jump?
            HostName bastion.example.com

        Match host bastion
            User matched

        Host "quoted name"
            HostName %h.example.com
        """
        let hosts = SSHConfig.hosts(in: text)
        #expect(hosts == [
            SSHConfigHost(alias: "bastion", hostName: "bastion.example.com", port: nil, user: nil, identityFile: nil),
            SSHConfigHost(alias: "quoted name", hostName: "quoted name.example.com", port: nil, user: "everyone", identityFile: nil),
        ])
    }

    @Test("關鍵字不分大小寫，無效的連接埠略過")
    func ignoresCaseAndBadPorts() {
        let text = """
        HOST box
          hostname box.local
          PORT notanumber
          user Pat
        """
        #expect(SSHConfig.hosts(in: text) == [
            SSHConfigHost(alias: "box", hostName: "box.local", port: nil, user: "Pat", identityFile: nil),
        ])
    }
}
