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

@Suite("PropfindResponseParser")
struct PropfindResponseParserTests {
    /// A typical Apache mod_dav reply: namespaced with the D: prefix.
    private let apacheStyle = """
    <?xml version="1.0" encoding="utf-8"?>
    <D:multistatus xmlns:D="DAV:">
      <D:response>
        <D:href>/dav/</D:href>
        <D:propstat>
          <D:prop>
            <D:resourcetype><D:collection/></D:resourcetype>
            <D:getlastmodified>Tue, 12 Aug 2026 10:00:00 GMT</D:getlastmodified>
          </D:prop>
          <D:status>HTTP/1.1 200 OK</D:status>
        </D:propstat>
      </D:response>
      <D:response>
        <D:href>/dav/report.pdf</D:href>
        <D:propstat>
          <D:prop>
            <D:resourcetype/>
            <D:getcontentlength>2048</D:getcontentlength>
            <D:getlastmodified>Wed, 13 Aug 2026 08:30:00 GMT</D:getlastmodified>
          </D:prop>
          <D:status>HTTP/1.1 200 OK</D:status>
        </D:propstat>
      </D:response>
    </D:multistatus>
    """

    @Test("解析集合與檔案")
    func parsesCollectionsAndFiles() throws {
        let entries = try PropfindResponseParser.parse(Data(apacheStyle.utf8))

        #expect(entries.count == 2)
        #expect(entries[0].isCollection)
        #expect(entries[0].href == "/dav/")
        #expect(!entries[1].isCollection)
        #expect(entries[1].contentLength == 2048)
        #expect(entries[1].lastModified != nil)
    }

    @Test("無命名空間前綴也能解析")
    func parsesWithoutNamespacePrefix() throws {
        let plain = """
        <?xml version="1.0"?>
        <multistatus xmlns="DAV:">
          <response>
            <href>/files/notes.txt</href>
            <propstat><prop>
              <resourcetype/>
              <getcontentlength>17</getcontentlength>
            </prop></propstat>
          </response>
        </multistatus>
        """
        let entries = try PropfindResponseParser.parse(Data(plain.utf8))

        #expect(entries.count == 1)
        #expect(entries[0].contentLength == 17)
        #expect(!entries[0].isCollection)
    }

    @Test("缺少屬性時長度為未知而非零")
    func reportsMissingLengthAsUnknown() throws {
        let sparse = """
        <?xml version="1.0"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response><D:href>/a.bin</D:href></D:response>
        </D:multistatus>
        """
        let entries = try PropfindResponseParser.parse(Data(sparse.utf8))

        #expect(entries[0].contentLength == nil)
        #expect(entries[0].lastModified == nil)
    }


    @Test("RFC 850 與 asctime 日期也能解析")
    func parsesLegacyDateFormats() throws {
        for date in ["Tuesday, 12-Aug-26 10:00:00 GMT", "Tue Aug 12 10:00:00 2026"] {
            let xml = """
            <?xml version="1.0"?>
            <D:multistatus xmlns:D="DAV:">
              <D:response>
                <D:href>/a.txt</D:href>
                <D:propstat><D:prop>
                  <D:getlastmodified>\(date)</D:getlastmodified>
                </D:prop></D:propstat>
              </D:response>
            </D:multistatus>
            """
            let entries = try PropfindResponseParser.parse(Data(xml.utf8))
            #expect(entries[0].lastModified != nil, "failed to parse \(date)")
        }
    }

    @Test("CDATA 包住的 href 不會讓項目消失")
    func keepsEntriesWithCDATAHrefs() throws {
        let xml = """
        <?xml version="1.0"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href><![CDATA[/dav/a&b.txt]]></D:href>
            <D:propstat><D:prop><D:getcontentlength>7</D:getcontentlength></D:prop></D:propstat>
          </D:response>
        </D:multistatus>
        """
        let entries = try PropfindResponseParser.parse(Data(xml.utf8))

        #expect(entries.count == 1)
        #expect(PropfindResponseParser.path(fromHref: entries[0].href) == "/dav/a&b.txt")
    }

    @Test("負數長度視為未知")
    func treatsNegativeLengthAsUnknown() throws {
        let xml = """
        <?xml version="1.0"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/a.bin</D:href>
            <D:propstat><D:prop><D:getcontentlength>-1</D:getcontentlength></D:prop></D:propstat>
          </D:response>
        </D:multistatus>
        """
        let entries = try PropfindResponseParser.parse(Data(xml.utf8))
        #expect(entries[0].contentLength == nil)
    }

    @Test("非 XML 內容回報錯誤")
    func rejectsNonXML() {
        #expect(throws: PropfindResponseParser.ParseError.notXML) {
            try PropfindResponseParser.parse(Data("not xml at all".utf8))
        }
    }

    @Test("沒有任何 response 時回報錯誤")
    func rejectsEmptyMultistatus() {
        let empty = """
        <?xml version="1.0"?>
        <D:multistatus xmlns:D="DAV:"></D:multistatus>
        """
        #expect(throws: PropfindResponseParser.ParseError.noResponses) {
            try PropfindResponseParser.parse(Data(empty.utf8))
        }
    }

    @Test("href 解碼百分比編碼並去掉結尾斜線")
    func decodesHref() {
        #expect(PropfindResponseParser.path(fromHref: "/dav/my%20folder/") == "/dav/my folder")
        #expect(PropfindResponseParser.path(fromHref: "/dav/a%2Bb.txt") == "/dav/a+b.txt")
        #expect(PropfindResponseParser.path(fromHref: "/") == "/")
    }

    @Test("href 是絕對網址時取出路徑")
    func decodesAbsoluteHref() {
        #expect(
            PropfindResponseParser.path(fromHref: "https://dav.example.com/files/report.pdf")
                == "/files/report.pdf"
        )
    }
}
