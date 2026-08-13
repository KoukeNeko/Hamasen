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

    @Test("缺少屬性時給安全的預設值")
    func toleratesMissingProperties() throws {
        let sparse = """
        <?xml version="1.0"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response><D:href>/a.bin</D:href></D:response>
        </D:multistatus>
        """
        let entries = try PropfindResponseParser.parse(Data(sparse.utf8))

        #expect(entries[0].contentLength == 0)
        #expect(entries[0].lastModified == nil)
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
