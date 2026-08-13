import Foundation

/// Parses the `multistatus` XML a WebDAV server returns from PROPFIND.
///
/// Servers vary in namespace prefix (`D:`, `d:`, none) and in which
/// properties they send, so the parser matches on local element names and
/// treats every property as optional.
public enum PropfindResponseParser {
    /// One `<response>` entry: an href plus the properties we care about.
    public struct Entry: Equatable, Sendable {
        public let href: String
        public let isCollection: Bool
        /// nil when the server did not report a usable length.
        public let contentLength: Int64?
        public let lastModified: Date?
    }

    public enum ParseError: Error, Equatable {
        case notXML
        case noResponses
    }

    public static func parse(_ data: Data) throws -> [Entry] {
        let delegate = MultiStatusDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        guard parser.parse() else { throw ParseError.notXML }
        guard !delegate.entries.isEmpty else { throw ParseError.noResponses }
        return delegate.entries
    }

    /// Decodes an href into a path: WebDAV hrefs are percent-encoded and may
    /// be absolute URLs rather than paths.
    public static func path(fromHref href: String) -> String {
        let raw: String
        if let components = URLComponents(string: href), components.host != nil {
            raw = components.percentEncodedPath
        } else {
            raw = href
        }
        let decoded = raw.removingPercentEncoding ?? raw
        return RemotePath.withoutTrailingSeparator(decoded)
    }
}

/// Accumulates `<response>` elements while the XML is streamed.
private final class MultiStatusDelegate: NSObject, XMLParserDelegate {
    private(set) var entries: [PropfindResponseParser.Entry] = []

    private var currentElement = ""
    private var text = ""

    private var href: String?
    private var isCollection = false
    private var contentLength: Int64?
    private var lastModified: Date?

    /// Every HTTP-date form: RFC 1123 is what WebDAV mandates, but RFC 850
    /// and asctime are still emitted by older servers. A date that fails to
    /// parse would collapse the item version onto the file size alone, so
    /// remote edits that preserve size would never be noticed.
    private static let modificationFormatters: [DateFormatter] = [
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "EEEE, dd-MMM-yy HH:mm:ss zzz",
        "EEE MMM d HH:mm:ss yyyy",
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }

    private static func parseModificationDate(_ text: String) -> Date? {
        for formatter in modificationFormatters {
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        currentElement = elementName.lowercased()
        text = ""
        switch currentElement {
        case "response":
            href = nil
            isCollection = false
            contentLength = nil
            lastModified = nil
        case "collection":
            isCollection = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    /// CDATA sections bypass foundCharacters entirely; without this an href
    /// wrapped in CDATA would be empty and the entry would be dropped.
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName.lowercased() {
        case "href":
            // Only the response's own href matters; nested hrefs (in lock
            // discovery, for instance) arrive after it and are ignored.
            if href == nil { href = trimmed }
        case "getcontentlength":
            // A negative length is as unusable as a missing one.
            contentLength = Int64(trimmed).flatMap { $0 >= 0 ? $0 : nil }
        case "getlastmodified":
            lastModified = Self.parseModificationDate(trimmed)
        case "response":
            if let href, !href.isEmpty {
                entries.append(
                    PropfindResponseParser.Entry(
                        href: href,
                        isCollection: isCollection,
                        contentLength: contentLength,
                        lastModified: lastModified
                    )
                )
            }
        default:
            break
        }
        text = ""
    }
}
