import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
@testable import HamasenCore

/// In-process WebDAV server backed by a temp directory, so WebDAV tests are
/// as hermetic as the SFTP ones: no external server, no network.
///
/// It implements just the verbs the app uses — PROPFIND, GET (including
/// Range), PUT, MKCOL, DELETE, MOVE — plus Basic authentication.
final class TestWebDAVServer {
    static let username = "davuser"
    static let password = "davpass"

    private static let portRange = 20000..<60000
    private static let maxBindAttempts = 5

    let port: Int
    let rootDirectory: URL
    private let channel: Channel
    private let group: MultiThreadedEventLoopGroup

    private init(port: Int, rootDirectory: URL, channel: Channel, group: MultiThreadedEventLoopGroup) {
        self.port = port
        self.rootDirectory = rootDirectory
        self.channel = channel
        self.group = group
    }

    static func start() async throws -> TestWebDAVServer {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("webdav-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(WebDAVHandler(root: rootDirectory))
                }
            }

        var lastError: Error?
        for _ in 0..<maxBindAttempts {
            let candidatePort = Int.random(in: portRange)
            do {
                let channel = try await bootstrap.bind(host: "127.0.0.1", port: candidatePort).get()
                return TestWebDAVServer(
                    port: candidatePort,
                    rootDirectory: rootDirectory,
                    channel: channel,
                    group: group
                )
            } catch {
                lastError = error
            }
        }
        try? await group.shutdownGracefully()
        throw lastError ?? RemoteFileServiceError.connectionFailed(underlying: "無法綁定測試埠")
    }

    func stop() async throws {
        try? await channel.close()
        try? await group.shutdownGracefully()
        try? FileManager.default.removeItem(at: rootDirectory)
    }
}

// MARK: - Request handling

private final class WebDAVHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let root: URL
    private var head: HTTPRequestHead?
    private var body = Data()

    init(root: URL) {
        self.root = root
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
            respond(to: head, body: body, context: context)
            self.head = nil
        }
    }

    // MARK: Routing

    private func respond(to head: HTTPRequestHead, body: Data, context: ChannelHandlerContext) {
        guard isAuthorized(head) else {
            send(status: .unauthorized, context: context)
            return
        }

        let path = decodedPath(head.uri)
        let target = localURL(for: path)

        switch head.method.rawValue {
        case "PROPFIND":
            handlePropfind(path: path, target: target, head: head, context: context)
        case "GET":
            handleGet(target: target, head: head, context: context)
        case "PUT":
            handlePut(target: target, body: body, context: context)
        case "MKCOL":
            handleMkcol(target: target, context: context)
        case "DELETE":
            handleDelete(target: target, context: context)
        case "MOVE":
            handleMove(target: target, head: head, context: context)
        default:
            send(status: .methodNotAllowed, context: context)
        }
    }

    private func isAuthorized(_ head: HTTPRequestHead) -> Bool {
        guard let header = head.headers.first(name: "Authorization"),
              header.hasPrefix("Basic "),
              let decoded = Data(base64Encoded: String(header.dropFirst("Basic ".count))),
              let pair = String(data: decoded, encoding: .utf8)
        else { return false }
        return pair == "\(TestWebDAVServer.username):\(TestWebDAVServer.password)"
    }

    // MARK: Verbs

    private func handlePropfind(
        path: String,
        target: URL,
        head: HTTPRequestHead,
        context: ChannelHandlerContext
    ) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: target.path) else {
            send(status: .notFound, context: context)
            return
        }
        let isDirectory = (attributes[.type] as? FileAttributeType) == .typeDirectory
        var responses = [propfindResponse(href: path, isDirectory: isDirectory, attributes: attributes)]

        let depth = head.headers.first(name: "Depth") ?? "1"
        if depth != "0", isDirectory {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: target.path)) ?? []
            for name in names.sorted() {
                let childURL = target.appendingPathComponent(name)
                guard let childAttributes = try? FileManager.default
                    .attributesOfItem(atPath: childURL.path) else { continue }
                responses.append(
                    propfindResponse(
                        href: path == "/" ? "/\(name)" : "\(path)/\(name)",
                        isDirectory: (childAttributes[.type] as? FileAttributeType) == .typeDirectory,
                        attributes: childAttributes
                    )
                )
            }
        }

        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
        \(responses.joined(separator: "\n"))
        </D:multistatus>
        """
        send(status: .multiStatus, body: Data(xml.utf8), context: context)
    }

    private func propfindResponse(
        href: String,
        isDirectory: Bool,
        attributes: [FileAttributeKey: Any]
    ) -> String {
        // An href is percent-encoded for the URL and then XML-escaped for the
        // document, exactly as a real server does: "&" survives percent
        // encoding of a path but is illegal raw inside XML.
        let percentEncoded = href.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? href
        let encodedHref = percentEncoded
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = Self.httpDateFormatter.string(
            from: attributes[.modificationDate] as? Date ?? Date()
        )
        let resourceType = isDirectory ? "<D:collection/>" : ""
        return """
          <D:response>
            <D:href>\(encodedHref)\(isDirectory && href != "/" ? "/" : "")</D:href>
            <D:propstat>
              <D:prop>
                <D:resourcetype>\(resourceType)</D:resourcetype>
                <D:getcontentlength>\(size)</D:getcontentlength>
                <D:getlastmodified>\(modified)</D:getlastmodified>
              </D:prop>
              <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
          </D:response>
        """
    }

    private func handleGet(target: URL, head: HTTPRequestHead, context: ChannelHandlerContext) {
        guard let contents = FileManager.default.contents(atPath: target.path) else {
            send(status: .notFound, context: context)
            return
        }
        guard let rangeHeader = head.headers.first(name: "Range"),
              let range = Self.parseRange(rangeHeader, fileSize: contents.count)
        else {
            send(status: .ok, body: contents, context: context)
            return
        }
        send(
            status: .partialContent,
            body: contents.subdata(in: range),
            extraHeaders: [
                "Content-Range": "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(contents.count)"
            ],
            context: context
        )
    }

    private func handlePut(target: URL, body: Data, context: ChannelHandlerContext) {
        do {
            try body.write(to: target)
            send(status: .created, context: context)
        } catch {
            send(status: .conflict, context: context)
        }
    }

    private func handleMkcol(target: URL, context: ChannelHandlerContext) {
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            send(status: .created, context: context)
        } catch {
            send(status: .conflict, context: context)
        }
    }

    private func handleDelete(target: URL, context: ChannelHandlerContext) {
        guard FileManager.default.fileExists(atPath: target.path) else {
            send(status: .notFound, context: context)
            return
        }
        do {
            try FileManager.default.removeItem(at: target)
            send(status: .noContent, context: context)
        } catch {
            send(status: .conflict, context: context)
        }
    }

    private func handleMove(target: URL, head: HTTPRequestHead, context: ChannelHandlerContext) {
        guard FileManager.default.fileExists(atPath: target.path) else {
            send(status: .notFound, context: context)
            return
        }
        guard let destination = head.headers.first(name: "Destination"),
              let destinationPath = URLComponents(string: destination)?.percentEncodedPath
        else {
            send(status: .badRequest, context: context)
            return
        }
        do {
            let destinationURL = localURL(for: decodedPath(destinationPath))
            try? FileManager.default.removeItem(at: destinationURL)
            try FileManager.default.moveItem(at: target, to: destinationURL)
            send(status: .created, context: context)
        } catch {
            send(status: .conflict, context: context)
        }
    }

    // MARK: Helpers

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()

    private static func parseRange(_ header: String, fileSize: Int) -> Range<Int>? {
        guard header.hasPrefix("bytes=") else { return nil }
        let parts = header.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
        guard let start = Int(parts.first ?? ""), start < fileSize else { return nil }
        let end = parts.count > 1 ? (Int(parts[1]) ?? fileSize - 1) : fileSize - 1
        return start..<min(end + 1, fileSize)
    }

    private func decodedPath(_ uri: String) -> String {
        let path = URLComponents(string: uri)?.percentEncodedPath ?? uri
        return path.removingPercentEncoding ?? path
    }

    /// Maps a request path under the server root, dropping "." and ".." so a
    /// request cannot escape it.
    private func localURL(for path: String) -> URL {
        path.split(separator: "/")
            .filter { $0 != "." && $0 != ".." }
            .reduce(root) { $0.appendingPathComponent(String($1)) }
    }

    private func send(
        status: HTTPResponseStatus,
        body: Data = Data(),
        extraHeaders: [String: String] = [:],
        context: ChannelHandlerContext
    ) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: String(body.count))
        for (name, value) in extraHeaders {
            headers.add(name: name, value: value)
        }
        if status == .unauthorized {
            headers.add(name: "WWW-Authenticate", value: "Basic realm=\"hamasen-test\"")
        }

        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        if !body.isEmpty {
            var buffer = context.channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}
