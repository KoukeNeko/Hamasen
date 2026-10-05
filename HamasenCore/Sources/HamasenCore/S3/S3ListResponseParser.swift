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

/// Parses the `ListBucketResult` XML that `ListObjectsV2` returns.
///
/// Providers agree on the element names and disagree on everything else:
/// which optional elements they send, in what order, and whether they echo
/// the encoding type at all. The parser therefore matches on local names,
/// treats every element except the key as optional, and never depends on
/// document order.
public enum S3ListResponseParser {
    /// One `<Contents>` entry. Only the fields a listing turns into a
    /// `RemoteItem`; the storage class and owner are read past.
    public struct Object: Equatable, Sendable {
        public let key: String
        public let size: Int64
        public let lastModified: Date?
        /// The ETag with its quotes removed; see `HTTPTransfer.normalizedETag`.
        public let contentTag: String?
    }

    public struct Listing: Equatable, Sendable {
        public let objects: [Object]
        /// The keys that stop at the delimiter. These are the only thing S3
        /// offers that resembles a subdirectory.
        public let commonPrefixes: [String]
        public let isTruncated: Bool
        /// Feeds the next request's `continuation-token`. Present exactly
        /// when the listing was truncated.
        public let nextContinuationToken: String?
    }

    public enum ParseError: Error, Equatable {
        case notXML
        /// The body parsed but was not a listing — an error document, or a
        /// proxy's own page returned with a 200.
        case notAListing
    }

    public static func parse(_ data: Data) throws -> Listing {
        let delegate = ListBucketResultDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        guard parser.parse() else { throw ParseError.notXML }
        guard delegate.sawListing else { throw ParseError.notAListing }
        return delegate.listing()
    }
}

/// Accumulates the listing while the XML is streamed.
///
/// Text is kept raw and decoded only once the whole document has been read,
/// because `EncodingType` may arrive after the keys it applies to — the
/// element order differs between providers and even between requests.
///
/// `Prefix` needs the enclosing element to be read at all: the listing echoes
/// the prefix that was asked for under the same name that `CommonPrefixes`
/// gives each of its children, so matching on the name alone reports the
/// directory being listed as a subdirectory of itself.
private final class ListBucketResultDelegate: NSObject, XMLParserDelegate {
    private(set) var sawListing = false

    private var text = ""
    private var isURLEncoded = false
    private var isTruncated = false
    private var nextContinuationToken: String?

    private var rawObjects: [(key: String, size: Int64, lastModified: Date?, contentTag: String?)] = []
    private var rawPrefixes: [String] = []

    private var key: String?
    private var size: Int64 = 0
    private var lastModified: Date?
    private var contentTag: String?
    private var insideContents = false
    private var insideCommonPrefixes = false

    /// S3 timestamps are ISO 8601 in UTC. The fractional part is present on
    /// Amazon and absent on some compatible implementations, and a listing
    /// whose dates all failed to parse would make every remote edit that
    /// preserved a file's size invisible.
    private static let timestampFormatters: [DateFormatter] = [
        "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
        "yyyy-MM-dd'T'HH:mm:ssXXXXX",
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }

    private static func timestamp(from text: String) -> Date? {
        for formatter in timestampFormatters {
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    func listing() -> S3ListResponseParser.Listing {
        S3ListResponseParser.Listing(
            objects: rawObjects.map {
                S3ListResponseParser.Object(
                    key: decoded($0.key), size: $0.size, lastModified: $0.lastModified,
                    contentTag: $0.contentTag)
            },
            commonPrefixes: rawPrefixes.map(decoded),
            isTruncated: isTruncated,
            // Opaque, and not one of the fields encoding-type applies to:
            // decoding it would send back a different token.
            nextContinuationToken: nextContinuationToken)
    }

    /// Percent-decoding is applied only when the server said it encoded, so a
    /// key that genuinely contains "%" is not mangled by a server that
    /// ignored the request parameter. The encoding is a form's: a space is
    /// "+" and a plus "%2B", as Amazon's own SDKs read it.
    private func decoded(_ value: String) -> String {
        guard isURLEncoded else { return value }
        let spaced = value.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        text = ""
        switch elementName.lowercased() {
        case "listbucketresult":
            sawListing = true
        case "contents":
            insideContents = true
            key = nil
            size = 0
            lastModified = nil
            contentTag = nil
        case "commonprefixes":
            insideCommonPrefixes = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName.lowercased() {
        case "encodingtype":
            isURLEncoded = value.lowercased() == "url"
        case "istruncated":
            isTruncated = value.lowercased() == "true"
        case "nextcontinuationtoken":
            nextContinuationToken = value
        case "key" where insideContents:
            key = value
        case "size" where insideContents:
            size = Int64(value) ?? 0
        case "lastmodified" where insideContents:
            lastModified = Self.timestamp(from: value)
        case "etag" where insideContents:
            contentTag = HTTPTransfer.normalizedETag(value)
        case "contents":
            // A Contents entry with no Key is not an object anybody can ask
            // for, so it is dropped rather than turned into a nameless item.
            if let key, !key.isEmpty {
                rawObjects.append((key, size, lastModified, contentTag))
            }
            insideContents = false
        case "prefix" where insideCommonPrefixes:
            if !value.isEmpty { rawPrefixes.append(value) }
        case "commonprefixes":
            insideCommonPrefixes = false
        default:
            break
        }
        text = ""
    }
}
