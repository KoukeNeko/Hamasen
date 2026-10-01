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

import Crypto
import Foundation
import NIOCore
import NIOHTTP1
import HamasenCore

/// Serves the subset of the S3 API the app uses, over the in-memory store.
final class S3Handler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let store: TestS3ObjectStore
    private let behaviour: TestS3Server.Behaviour
    private var head: HTTPRequestHead?
    private var body = Data()

    init(store: TestS3ObjectStore, behaviour: TestS3Server.Behaviour) {
        self.store = store
        self.behaviour = behaviour
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            body = Data()
        case .body(var buffer):
            if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                body.append(contentsOf: bytes)
            }
        case .end:
            guard let head else { return }
            respond(to: head, context: context)
            self.head = nil
        }
    }

    // MARK: - Routing

    private struct Target {
        let bucket: String
        /// Decoded. Empty means the request addresses the bucket itself.
        let key: String
        let query: [String: String]
    }

    private func respond(to head: HTTPRequestHead, context: ChannelHandlerContext) {
        do {
            try TestS3SignatureVerifier.verify(
                method: head.method.rawValue,
                uri: head.uri,
                headers: head.headers.map { (name: $0.name, value: $0.value) },
                body: body,
                credentials: TestS3Server.credentials)
        } catch {
            // Real services say no more than this, which is exactly why the
            // signature has to be pinned by unit tests rather than debugged
            // from a response. The reason is put in the message so a failing
            // test here does not have to be debugged the same way.
            send(error: "SignatureDoesNotMatch", message: "\(error)",
                 status: .forbidden, context: context)
            return
        }

        let target = parse(uri: head.uri)
        guard target.bucket == TestS3Server.bucket else {
            send(error: "NoSuchBucket", message: "no such bucket: \(target.bucket)",
                 status: .notFound, context: context)
            return
        }

        let isWrite = ["PUT", "POST", "DELETE"].contains(head.method.rawValue)
        if behaviour.forbidsWrites && isWrite {
            send(error: "AccessDenied", message: "this key may only read",
                 status: .forbidden, context: context)
            return
        }
        if let limit = behaviour.failWritesAfter, isWrite {
            // An abort is a DELETE, and refusing it too would make the test
            // unable to tell a client that gave up cleanly from one that did
            // not clean up at all.
            let isAbort = head.uri.contains("uploadId") && head.method == .DELETE
            if !isAbort {
                store.recordWrite()
                if store.writeCount > limit {
                    send(error: "InternalError", message: "write \(store.writeCount) refused",
                         status: .internalServerError, context: context)
                    return
                }
            }
        }

        switch (head.method, target.key.isEmpty) {
        case (.HEAD, true):
            send(status: .ok, context: context)
        case (.GET, true):
            listObjects(target, context: context)
        case (.POST, true) where target.query["delete"] != nil:
            deleteObjects(context: context)
        case (.HEAD, false):
            headObject(target, context: context)
        case (.GET, false):
            getObject(target, head: head, context: context)
        case (.PUT, false):
            putObject(target, head: head, context: context)
        case (.POST, false):
            postObject(target, context: context)
        case (.DELETE, false):
            deleteObject(target, context: context)
        default:
            send(error: "MethodNotAllowed", message: "\(head.method) \(head.uri)",
                 status: .methodNotAllowed, context: context)
        }
    }

    private func parse(uri: String) -> Target {
        let separator = uri.firstIndex(of: "?")
        let rawPath = separator.map { String(uri[uri.startIndex..<$0]) } ?? uri
        let rawQuery = separator.map { String(uri[uri.index(after: $0)...]) } ?? ""

        var query: [String: String] = [:]
        for field in rawQuery.split(separator: "&") {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(pair[0]).removingPercentEncoding ?? String(pair[0])
            let value = pair.count > 1 ? String(pair[1]) : ""
            query[name] = value.removingPercentEncoding ?? value
        }

        let trimmed = rawPath.hasPrefix("/") ? String(rawPath.dropFirst()) : rawPath
        guard let slash = trimmed.firstIndex(of: "/") else {
            return Target(bucket: trimmed.removingPercentEncoding ?? trimmed, key: "", query: query)
        }
        let bucket = String(trimmed[trimmed.startIndex..<slash])
        let key = String(trimmed[trimmed.index(after: slash)...])
        return Target(
            bucket: bucket.removingPercentEncoding ?? bucket,
            key: key.removingPercentEncoding ?? key,
            query: query)
    }

    // MARK: - Listing

    private enum Entry {
        case object(String)
        case commonPrefix(String)
    }

    private func listObjects(_ target: Target, context: ChannelHandlerContext) {
        store.recordListing()
        let prefix = target.query["prefix"] ?? ""
        let delimiter = target.query["delimiter"].flatMap { $0.isEmpty ? nil : $0 }
        let requestedMax = target.query["max-keys"].flatMap(Int.init) ?? behaviour.maxKeysPerPage
        let maxKeys = max(1, min(requestedMax, behaviour.maxKeysPerPage))
        let urlEncode = !behaviour.ignoresEncodingType
            && target.query["encoding-type"]?.lowercased() == "url"
        let after = target.query["continuation-token"]
            .flatMap { Data(base64Encoded: $0) }
            .flatMap { String(data: $0, encoding: .utf8) }

        var seen = Set<String>()
        var entries: [(sortKey: String, entry: Entry)] = []
        for key in store.sortedKeys() where key.hasPrefix(prefix) {
            let remainder = key.dropFirst(prefix.count)
            if let delimiter, let range = remainder.range(of: delimiter) {
                let common = prefix + remainder[remainder.startIndex..<range.upperBound]
                if seen.insert(common).inserted { entries.append((common, .commonPrefix(common))) }
            } else {
                // The zero-byte marker of an empty folder lands here, as an
                // object whose name after the prefix is empty. Real services
                // do the same, and the client is the one that has to filter it.
                entries.append((key, .object(key)))
            }
        }
        entries.sort { $0.sortKey < $1.sortKey }

        if let after {
            entries = entries.filter { $0.sortKey > after }
        }
        let page = Array(entries.prefix(maxKeys))
        let isTruncated = entries.count > page.count

        var xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
            <Name>\(TestS3Server.bucket)</Name>
            <Prefix>\(text(prefix, urlEncode: urlEncode))</Prefix>
            <MaxKeys>\(maxKeys)</MaxKeys>
            <KeyCount>\(page.count)</KeyCount>
            <IsTruncated>\(isTruncated)</IsTruncated>

            """
        if let delimiter {
            xml += "<Delimiter>\(text(delimiter, urlEncode: urlEncode))</Delimiter>\n"
        }
        if urlEncode { xml += "<EncodingType>url</EncodingType>\n" }
        if isTruncated, !behaviour.omitsContinuationToken, let last = page.last?.sortKey {
            let token = Data(last.utf8).base64EncodedString()
            xml += "<NextContinuationToken>\(escaped(token))</NextContinuationToken>\n"
        }
        for (_, entry) in page {
            switch entry {
            case .object(let key):
                guard let stored = store.object(forKey: key) else { continue }
                xml += """
                    <Contents><Key>\(text(key, urlEncode: urlEncode))</Key>\
                    <LastModified>\(Self.timestamp(stored.lastModified))</LastModified>\
                    <ETag>&quot;\(Self.entityTag(for: stored.data))&quot;</ETag>\
                    <Size>\(stored.data.count)</Size>\
                    <StorageClass>STANDARD</StorageClass></Contents>

                    """
            case .commonPrefix(let common):
                xml += "<CommonPrefixes><Prefix>"
                    + text(common, urlEncode: urlEncode) + "</Prefix></CommonPrefixes>\n"
            }
        }
        xml += "</ListBucketResult>"
        send(status: .ok, body: Data(xml.utf8),
             contentType: "application/xml", context: context)
    }

    // MARK: - Objects

    /// A HEAD carries no body, which cuts both ways: the client has only the
    /// status to read a failure from, and the size has to be declared in a
    /// header or there is no way to learn it without downloading the object.
    private func headObject(_ target: Target, context: ChannelHandlerContext) {
        guard let stored = store.object(forKey: target.key) else {
            send(status: .notFound, context: context)
            return
        }
        send(status: .ok, contentLength: stored.data.count,
             extraHeaders: objectHeaders(for: stored), context: context)
    }

    private func getObject(_ target: Target, head: HTTPRequestHead,
                           context: ChannelHandlerContext) {
        guard let stored = store.object(forKey: target.key) else {
            send(error: "NoSuchKey", message: "no such key: \(target.key)",
                 status: .notFound, context: context)
            return
        }
        guard let range = head.headers.first(name: "Range"), !behaviour.ignoresRange else {
            send(status: .ok, body: stored.data, contentType: "application/octet-stream",
                 extraHeaders: objectHeaders(for: stored), context: context)
            return
        }
        guard let bounds = Self.byteRange(range, count: stored.data.count) else {
            send(status: .rangeNotSatisfiable, context: context)
            return
        }
        let slice = stored.data.subdata(in: bounds)
        var headers = objectHeaders(for: stored)
        headers["Content-Range"] =
            "bytes \(bounds.lowerBound)-\(bounds.upperBound - 1)/\(stored.data.count)"
        send(status: .partialContent, body: slice, contentType: "application/octet-stream",
             extraHeaders: headers, context: context)
    }

    private func putObject(_ target: Target, head: HTTPRequestHead,
                           context: ChannelHandlerContext) {
        if let uploadID = target.query["uploadId"],
           let number = target.query["partNumber"].flatMap(Int.init) {
            if let source = head.headers.first(name: "x-amz-copy-source") {
                copyPart(from: source, range: head.headers.first(name: "x-amz-copy-source-range"),
                         ifMatch: head.headers.first(name: "x-amz-copy-source-if-match"),
                         number: number, uploadID: uploadID, context: context)
                return
            }
            guard store.addPart(body, number: number, entityTag: Self.entityTag(for: body),
                                toUpload: uploadID) else {
                send(error: "NoSuchUpload", message: uploadID, status: .notFound, context: context)
                return
            }
            send(status: .ok,
                 extraHeaders: ["ETag": "\"\(Self.entityTag(for: body))\""], context: context)
            return
        }

        if let source = head.headers.first(name: "x-amz-copy-source") {
            copyObject(from: source, to: target.key,
                       ifMatch: head.headers.first(name: "x-amz-copy-source-if-match"), context: context)
            return
        }

        store.put(body, forKey: target.key)
        send(status: .ok,
             extraHeaders: ["ETag": "\"\(Self.entityTag(for: body))\""], context: context)
    }

    /// The header names the source as /bucket/key, percent-encoded. Sends the
    /// error itself and returns nil when it cannot be resolved.
    private func copySource(_ source: String, ifMatch: String?, context: ChannelHandlerContext)
        -> TestS3ObjectStore.StoredObject? {
        let decoded = source.removingPercentEncoding ?? source
        let trimmed = decoded.hasPrefix("/") ? String(decoded.dropFirst()) : decoded
        guard let slash = trimmed.firstIndex(of: "/") else {
            send(error: "InvalidArgument", message: "x-amz-copy-source: \(source)",
                 status: .badRequest, context: context)
            return nil
        }
        let sourceKey = String(trimmed[trimmed.index(after: slash)...])
        guard let stored = store.object(forKey: sourceKey) else {
            send(error: "NoSuchKey", message: "no such key: \(sourceKey)",
                 status: .notFound, context: context)
            return nil
        }
        // As S3 does: a copy pinned to an ETag the source no longer has is
        // refused rather than made from whatever is there now.
        if let ifMatch, ifMatch != "\"\(Self.entityTag(for: stored.data))\"" {
            send(error: "PreconditionFailed", message: "x-amz-copy-source-if-match: \(ifMatch)",
                 status: .preconditionFailed, context: context)
            return nil
        }
        return stored
    }

    private func copyPart(from source: String, range: String?, ifMatch: String?, number: Int,
                          uploadID: String, context: ChannelHandlerContext) {
        guard let stored = copySource(source, ifMatch: ifMatch, context: context) else { return }
        var part = stored.data
        if let range {
            guard let bounds = Self.byteRange(range.replacingOccurrences(of: "bytes ", with: "bytes="),
                                              count: stored.data.count) else {
                send(error: "InvalidArgument", message: "x-amz-copy-source-range: \(range)",
                     status: .badRequest, context: context)
                return
            }
            part = stored.data.subdata(in: bounds)
        }
        let tag = Self.entityTag(for: part)
        guard store.addPart(part, number: number, entityTag: tag, toUpload: uploadID) else {
            send(error: "NoSuchUpload", message: uploadID, status: .notFound, context: context)
            return
        }
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <CopyPartResult><LastModified>\(Self.timestamp(Date()))</LastModified>\
            <ETag>&quot;\(tag)&quot;</ETag></CopyPartResult>
            """
        send(status: .ok, body: Data(xml.utf8), contentType: "application/xml", context: context)
    }

    private func copyObject(from source: String, to key: String, ifMatch: String?,
                            context: ChannelHandlerContext) {
        guard let stored = copySource(source, ifMatch: ifMatch, context: context) else { return }
        if let limit = behaviour.maxCopySourceBytes, stored.data.count > limit {
            send(error: "InvalidRequest",
                 message: "The specified copy source is larger than the maximum allowable size for a copy source: \(limit)",
                 status: .badRequest, context: context)
            return
        }
        if behaviour.copyFailsWithStatusOK {
            send(errorWithStatusOK: "InternalError", message: "copy did not complete",
                 context: context)
            return
        }
        if behaviour.copyAnswersEmptyOK {
            send(status: .ok, context: context)
            return
        }
        store.put(stored.data, forKey: key)
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <CopyObjectResult><LastModified>\(Self.timestamp(Date()))</LastModified>\
            <ETag>&quot;\(Self.entityTag(for: stored.data))&quot;</ETag></CopyObjectResult>
            """
        send(status: .ok, body: Data(xml.utf8), contentType: "application/xml", context: context)
    }

    private func deleteObject(_ target: Target, context: ChannelHandlerContext) {
        if let uploadID = target.query["uploadId"] {
            _ = store.abortUpload(uploadID)
            send(status: .noContent, context: context)
            return
        }
        // S3 answers 204 whether or not the key was there, so a delete is
        // safe to repeat.
        store.remove(key: target.key)
        send(status: .noContent, context: context)
    }

    private func deleteObjects(context: ChannelHandlerContext) {
        let keys = Self.values(ofElement: "key", in: body)
        let refused = keys.filter(behaviour.deleteRefusedKeys.contains)
        for key in keys where !refused.contains(key) { store.remove(key: key) }
        let deleted = keys.filter { !refused.contains($0) }
            .map { "<Deleted><Key>\(escaped($0))</Key></Deleted>" }
            .joined(separator: "\n")
        let errors = refused
            .map { "<Error><Key>\(escaped($0))</Key><Code>AccessDenied</Code><Message>Access Denied</Message></Error>" }
            .joined(separator: "\n")
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <DeleteResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
            \(deleted)
            \(errors)
            </DeleteResult>
            """
        send(status: .ok, body: Data(xml.utf8), contentType: "application/xml", context: context)
    }

    // MARK: - Multipart

    private func postObject(_ target: Target, context: ChannelHandlerContext) {
        if target.query["uploads"] != nil {
            let id = store.beginUpload()
            let xml = """
                <?xml version="1.0" encoding="UTF-8"?>
                <InitiateMultipartUploadResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
                <Bucket>\(TestS3Server.bucket)</Bucket><Key>\(escaped(target.key))</Key>
                <UploadId>\(escaped(id))</UploadId></InitiateMultipartUploadResult>
                """
            send(status: .ok, body: Data(xml.utf8), contentType: "application/xml",
                 context: context)
            return
        }
        guard let uploadID = target.query["uploadId"] else {
            send(error: "InvalidRequest", message: "POST with neither uploads nor uploadId",
                 status: .badRequest, context: context)
            return
        }
        if behaviour.completeFailsWithStatusOK {
            send(errorWithStatusOK: "InternalError", message: "assembly did not complete",
                 context: context)
            return
        }
        let numbers = Self.values(ofElement: "partnumber", in: body).compactMap(Int.init)
        let tags = Self.values(ofElement: "etag", in: body)
        // ETags are read positionally, so one left off a part shifts the rest
        // out of line; a request naming fewer tags than parts is refused.
        let requested = numbers.enumerated().map {
            (number: $0.element, entityTag: $0.offset < tags.count && tags.count == numbers.count ? tags[$0.offset] : nil)
        }
        let assembled: Data
        switch store.completeUpload(uploadID, parts: requested) {
        case .success(let data):
            assembled = data
        case .failure(let failure):
            send(error: failure.rawValue, message: "CompleteMultipartUpload refused: \(failure)",
                 status: failure == .noSuchUpload ? .notFound : .badRequest, context: context)
            return
        }
        store.put(assembled, forKey: target.key)
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <CompleteMultipartUploadResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
            <Bucket>\(TestS3Server.bucket)</Bucket><Key>\(escaped(target.key))</Key>
            <ETag>&quot;\(Self.entityTag(for: assembled))&quot;</ETag>
            </CompleteMultipartUploadResult>
            """
        send(status: .ok, body: Data(xml.utf8), contentType: "application/xml", context: context)
    }

    // MARK: - Rendering

    private func objectHeaders(for stored: TestS3ObjectStore.StoredObject) -> [String: String] {
        [
            "ETag": "\"\(Self.entityTag(for: stored.data))\"",
            "Last-Modified": Self.httpDate(stored.lastModified),
            "x-amz-meta-modified": Self.timestamp(stored.lastModified),
        ]
    }

    private func text(_ value: String, urlEncode: Bool) -> String {
        guard urlEncode else { return escaped(value) }
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return escaped(value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value)
    }

    private func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func send(
        status: HTTPResponseStatus,
        body: Data = Data(),
        contentType: String? = nil,
        contentLength: Int? = nil,
        extraHeaders: [String: String] = [:],
        context: ChannelHandlerContext
    ) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: String(contentLength ?? body.count))
        if let contentType { headers.add(name: "Content-Type", value: contentType) }
        for (name, value) in extraHeaders { headers.add(name: name, value: value) }

        context.write(
            wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status,
                                                   headers: headers))), promise: nil)
        if !body.isEmpty {
            var buffer = context.channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    /// A failure reported after the service had already committed to 200,
    /// which is where CopyObject and CompleteMultipartUpload put one.
    private func send(errorWithStatusOK code: String, message: String,
                      context: ChannelHandlerContext) {
        send(error: code, message: message, status: .ok, context: context)
    }

    private func send(
        error code: String, message: String, status: HTTPResponseStatus,
        context: ChannelHandlerContext
    ) {
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <Error><Code>\(escaped(code))</Code><Message>\(escaped(message))</Message>
            <RequestId>test</RequestId></Error>
            """
        send(status: status, body: Data(xml.utf8), contentType: "application/xml",
             context: context)
    }

    // MARK: - Helpers

    /// S3 uses the body's MD5 for a single-part object. Nothing here depends
    /// on the value, only on its being stable across a round trip.
    private static func entityTag(for data: Data) -> String {
        Insecure.MD5.hash(data: data).reduce(into: "") { $0 += String(format: "%02x", $1) }
    }

    private static let listingFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter
    }()

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()

    private static func timestamp(_ date: Date) -> String { listingFormatter.string(from: date) }
    private static func httpDate(_ date: Date) -> String { httpDateFormatter.string(from: date) }

    /// Parses "bytes=start-end" and "bytes=start-", the only forms the client
    /// sends. Returns nil when the range cannot be satisfied.
    static func byteRange(_ header: String, count: Int) -> Range<Int>? {
        guard header.hasPrefix("bytes=") else { return nil }
        let bounds = header.dropFirst("bytes=".count).split(
            separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let start = Int(bounds[0]), start < count else { return nil }
        guard bounds.count > 1, !bounds[1].isEmpty, let inclusiveEnd = Int(bounds[1]) else {
            return start..<count
        }
        return start..<min(inclusiveEnd + 1, count)
    }

    /// The text of every element with this local name, in document order.
    /// Enough for the two request bodies the client sends.
    static func values(ofElement name: String, in data: Data) -> [String] {
        let delegate = ElementTextDelegate(elementName: name)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        guard parser.parse() else { return [] }
        return delegate.values
    }
}

private final class ElementTextDelegate: NSObject, XMLParserDelegate {
    private let elementName: String
    private(set) var values: [String] = []
    private var text = ""

    init(elementName: String) {
        self.elementName = elementName
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String]
    ) {
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName: String?
    ) {
        if elementName.lowercased() == self.elementName {
            values.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        text = ""
    }
}
