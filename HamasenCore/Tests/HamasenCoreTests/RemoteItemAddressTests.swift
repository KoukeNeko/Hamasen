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

@Suite("Item addresses")
struct RemoteItemAddressTests {
    private static func address(
        _ path: String, _ transferProtocol: ServerConfig.TransferProtocol, host: String = "nas.local",
        port: Int? = nil, username: String = "kai", remotePath: String = RemotePath.root
    ) -> String? {
        let config = ServerConfig(
            name: "test", transferProtocol: transferProtocol, host: host,
            port: port ?? transferProtocol.defaultPort, username: username, remotePath: remotePath)
        return RemoteItemAddress.url(of: path, on: config)?.absoluteString
    }

    @Test("檔案協定帶使用者名稱，預設連接埠省略")
    func fileProtocolsNameTheUser() {
        #expect(Self.address("/docs/a.txt", .sftp, remotePath: "/home/kai") == "sftp://kai@nas.local/home/kai/docs/a.txt")
        #expect(Self.address("/a.txt", .sftp, port: 2222) == "sftp://kai@nas.local:2222/a.txt")
        #expect(Self.address("/pub", .ftps) == "ftps://kai@nas.local/pub")
        #expect(Self.address("/Share/b c.txt", .smb) == "smb://kai@nas.local/Share/b%20c.txt")
    }

    @Test("WebDAV 用伺服器自己的網址，不帶帳號")
    func webDAVUsesItsOwnAddress() {
        #expect(Self.address("/x.md", .webdavs, remotePath: "/dav") == "https://nas.local/dav/x.md")
        #expect(Self.address("/x.md", .webdav, port: 8080) == "http://nas.local:8080/x.md")
    }

    @Test("IPv6 位址要加中括號")
    func bracketsAnIPv6Host() {
        #expect(Self.address("/a", .sftp, host: "fe80::1") == "sftp://kai@[fe80::1]/a")
    }

    @Test("S3 依端點組出物件網址")
    func s3NamesTheObject() {
        #expect(Self.address("/photos/cat.jpg", .s3, host: "minio.local") == "https://minio.local/photos/cat.jpg")
    }

    @Test("雲端硬碟沒有可推算的位址")
    func cloudDrivesHaveNone() {
        #expect(Self.address("/Report.docx", .googleDrive, host: "") == nil)
        #expect(Self.address("/Report.docx", .dropbox, host: "") == nil)
    }

    @Test("App 連結能來回解析連線")
    func appLinkRoundTrips() {
        let id = UUID()
        #expect(AppLink.connectionID(in: AppLink.connection(id)) == id)
        #expect(AppLink.connectionID(in: URL(string: "https://example.com/\(id.uuidString)")!) == nil)
    }
}
