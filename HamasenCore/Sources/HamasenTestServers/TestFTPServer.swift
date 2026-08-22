import Foundation
import NIOCore
import NIOPosix
import HamasenCore

/// An FTP server that runs in the test process, backed by a real directory.
///
/// The other protocols here are tested against a server of their own for the
/// same reason: an FTP client cannot be checked against parsing alone, since
/// most of what can go wrong — passive mode, the two-part end of a transfer,
/// REST — only happens between two connections.
///
/// It speaks the subset this client uses, and no more.
public final class TestFTPServer {
    public static let username = "testuser"
    public static let password = "testpass"

    private static let portRange = 20000..<60000
    private static let maxBindAttempts = 5

    public let port: Int
    public let rootDirectory: URL
    private let channel: Channel
    private let transferred: TransferredBytes

    /// How many bytes of the last download the server managed to send.
    ///
    /// A client that stops early leaves this short of the file, which is the
    /// only way from outside to tell a ranged read that stopped from one that
    /// read everything and discarded the rest.
    public var bytesSentInLastDownload: Int { transferred.count }

    private init(port: Int, rootDirectory: URL, channel: Channel, transferred: TransferredBytes) {
        self.port = port
        self.rootDirectory = rootDirectory
        self.channel = channel
        self.transferred = transferred
    }

    /// - Parameter preferredPort: a fixed port, for a server someone is
    ///   going to connect to by hand. Zero picks a free one, which is what
    ///   tests want so they can run side by side.
    public static func start(
        advertisingMLSD: Bool = true,
        preferredPort: Int = 0
    ) async throws -> TestFTPServer {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

        let transferred = TransferredBytes()
        var lastError: Error?
        for _ in 0..<maxBindAttempts {
            let candidatePort = preferredPort > 0 ? preferredPort : Int.random(in: portRange)
            do {
                let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                    .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                    .childChannelInitializer { channel in
                        channel.eventLoop.makeCompletedFuture {
                            try channel.pipeline.syncOperations.addHandlers([
                                ByteToMessageHandler(FTPLineDecoder()),
                                FTPSessionHandler(
                                    root: rootDirectory,
                                    advertisesMLSD: advertisingMLSD,
                                    transferred: transferred
                                ),
                            ])
                        }
                    }
                    .bind(host: "127.0.0.1", port: candidatePort)
                    .get()
                return TestFTPServer(
                    port: candidatePort,
                    rootDirectory: rootDirectory,
                    channel: channel,
                    transferred: transferred
                )
            } catch {
                lastError = error
            }
        }
        throw lastError ?? RemoteFileServiceError.connectionFailed(underlying: "無法綁定測試埠")
    }

    public func stop() async throws {
        try? await channel.close()
        try? FileManager.default.removeItem(at: rootDirectory)
    }
}

/// One client session. Every command is handled where it arrives, on the
/// channel's event loop, which is enough for the sizes a test moves.
private final class FTPSessionHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = String
    typealias OutboundOut = ByteBuffer

    private let root: URL
    private let advertisesMLSD: Bool
    private let transferred: TransferredBytes
    private var isAuthenticated = false
    private var workingDirectory = "/"
    private var renameSource: String?
    private var restartOffset: Int64 = 0
    /// The listener opened by PASV/EPSV, waiting for the client to connect.
    private var passiveListener: Channel?
    private var passiveConnection: EventLoopFuture<Channel>?

    init(root: URL, advertisesMLSD: Bool, transferred: TransferredBytes) {
        self.root = root
        self.advertisesMLSD = advertisesMLSD
        self.transferred = transferred
    }

    func channelActive(context: ChannelHandlerContext) {
        reply(context, 220, "Test FTP ready")
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let line = unwrapInboundIn(data)
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let command = String(parts.first ?? "").uppercased()
        let argument = parts.count > 1 ? String(parts[1]) : ""

        switch command {
        case "USER":
            reply(context, argument == TestFTPServer.username ? 331 : 530, "Need password")
        case "PASS":
            isAuthenticated = argument == TestFTPServer.password
            reply(context, isAuthenticated ? 230 : 530, isAuthenticated ? "Logged in" : "Not logged in")
        case "FEAT":
            var features = [" SIZE", " MDTM", " UTF8", " EPSV", " REST STREAM"]
            if advertisesMLSD { features.insert(" MLSD", at: 0) }
            replyLines(context, 211, ["Features:"] + features + ["End"])
        case "OPTS", "TYPE", "NOOP":
            reply(context, 200, "OK")
        case "PWD":
            reply(context, 257, "\"\(workingDirectory)\" is the current directory")
        case "QUIT":
            reply(context, 221, "Bye")
            context.close(promise: nil)
        default:
            guard isAuthenticated else { return reply(context, 530, "Not logged in") }
            handleAuthenticated(command, argument, context)
        }
    }

    private func handleAuthenticated(
        _ command: String,
        _ argument: String,
        _ context: ChannelHandlerContext
    ) {
        switch command {
        case "CWD":
            let url = localURL(for: argument)
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if exists && isDirectory.boolValue {
                workingDirectory = normalized(argument)
                reply(context, 250, "OK")
            } else {
                reply(context, 550, "No such directory")
            }
        case "SIZE":
            let attributes = try? FileManager.default.attributesOfItem(atPath: localURL(for: argument).path)
            if let size = attributes?[.size] as? NSNumber {
                reply(context, 213, "\(size.int64Value)")
            } else {
                reply(context, 550, "No such file")
            }
        case "MDTM":
            let attributes = try? FileManager.default.attributesOfItem(atPath: localURL(for: argument).path)
            if let date = attributes?[.modificationDate] as? Date {
                reply(context, 213, Self.timestampFormatter.string(from: date))
            } else {
                reply(context, 550, "No such file")
            }
        case "EPSV", "PASV":
            openPassiveListener(command, context)
        case "REST":
            restartOffset = Int64(argument) ?? 0
            reply(context, 350, "Restarting at \(restartOffset)")
        case "MLSD", "LIST":
            sendListing(argument, machineReadable: command == "MLSD", context)
        case "RETR":
            sendFile(argument, context)
        case "STOR":
            receiveFile(argument, context)
        case "DELE":
            perform(context) { try FileManager.default.removeItem(at: self.localURL(for: argument)) }
        case "MKD":
            perform(context) {
                try FileManager.default.createDirectory(
                    at: self.localURL(for: argument), withIntermediateDirectories: false
                )
            }
        case "RMD":
            perform(context) { try FileManager.default.removeItem(at: self.localURL(for: argument)) }
        case "RNFR":
            renameSource = argument
            reply(context, 350, "Ready for RNTO")
        case "RNTO":
            guard let source = renameSource else { return reply(context, 503, "RNFR first") }
            renameSource = nil
            perform(context) {
                try FileManager.default.moveItem(
                    at: self.localURL(for: source), to: self.localURL(for: argument)
                )
            }
        default:
            reply(context, 502, "Not implemented")
        }
    }

    // MARK: - Data connection

    private func openPassiveListener(_ command: String, _ context: ChannelHandlerContext) {
        passiveListener?.close(promise: nil)
        let accepted = context.eventLoop.makePromise(of: Channel.self)
        passiveConnection = accepted.futureResult

        ServerBootstrap(group: context.eventLoop)
            .childChannelInitializer { channel in
                accepted.succeed(channel)
                return channel.eventLoop.makeSucceededVoidFuture()
            }
            .bind(host: "127.0.0.1", port: 0)
            .whenComplete { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let listener):
                    self.passiveListener = listener
                    let port = listener.localAddress?.port ?? 0
                    if command == "EPSV" {
                        self.reply(context, 229, "Entering Extended Passive Mode (|||\(port)|)")
                    } else {
                        self.reply(context, 227, "Entering Passive Mode (127,0,0,1,\(port >> 8),\(port & 0xFF))")
                    }
                case .failure:
                    self.reply(context, 425, "Cannot open data connection")
                }
            }
    }

    /// Hands `body` to the client over the waiting data connection, then
    /// closes it and reports completion — the two halves the client waits for.
    /// Written in pieces rather than in one go, so a client that stops
    /// reading part-way through leaves a write that fails — which is what a
    /// real server sees, and what makes an early stop visible to a test.
    private static let chunkSize = 64 * 1024

    private func sendOverDataConnection(_ body: Data, _ context: ChannelHandlerContext) {
        guard let pending = passiveConnection else { return reply(context, 425, "Use PASV first") }
        transferred.reset()
        reply(context, 150, "Opening data connection")
        pending.whenSuccess { [weak self] channel in
            self?.sendChunk(of: body, from: 0, over: channel, context)
        }
    }

    private func sendChunk(
        of body: Data,
        from offset: Int,
        over channel: Channel,
        _ context: ChannelHandlerContext
    ) {
        guard offset < body.count else {
            channel.close(promise: nil)
            closePassiveListener()
            return reply(context, 226, "Transfer complete")
        }
        let end = min(offset + Self.chunkSize, body.count)
        var buffer = channel.allocator.buffer(capacity: end - offset)
        buffer.writeBytes(body[body.startIndex + offset..<body.startIndex + end])

        channel.writeAndFlush(buffer).whenComplete { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.transferred.add(end - offset)
                self.sendChunk(of: body, from: end, over: channel, context)
            case .failure:
                // The client closed before this finished, which is what a
                // ranged read looks like from here.
                self.closePassiveListener()
                self.reply(context, 426, "Connection closed; transfer aborted")
            }
        }
    }

    private func sendListing(_ argument: String, machineReadable: Bool, _ context: ChannelHandlerContext) {
        let directory = localURL(for: argument)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let body = names.sorted().compactMap { name -> String? in
            let url = directory.appendingPathComponent(name)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
                return nil
            }
            let isDirectory = (attributes[.type] as? FileAttributeType) == .typeDirectory
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attributes[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
            if machineReadable {
                return "type=\(isDirectory ? "dir" : "file");size=\(size);"
                    + "modify=\(Self.timestampFormatter.string(from: modified)); \(name)"
            }
            return "\(isDirectory ? "d" : "-")rw-r--r--   1 owner group \(size) "
                + "\(Self.listFormatter.string(from: modified)) \(name)"
        }.joined(separator: "\r\n")
        sendOverDataConnection(Data((body + "\r\n").utf8), context)
    }

    private func sendFile(_ argument: String, _ context: ChannelHandlerContext) {
        guard var contents = FileManager.default.contents(atPath: localURL(for: argument).path) else {
            return reply(context, 550, "No such file")
        }
        if restartOffset > 0 {
            contents = contents.count > Int(restartOffset) ? contents.dropFirst(Int(restartOffset)) : Data()
            restartOffset = 0
        }
        sendOverDataConnection(contents, context)
    }

    private func receiveFile(_ argument: String, _ context: ChannelHandlerContext) {
        guard let pending = passiveConnection else { return reply(context, 425, "Use PASV first") }
        let destination = localURL(for: argument)
        reply(context, 150, "Ready to receive")
        pending.whenSuccess { [weak self] channel in
            guard let self else { return }
            let collector = UploadCollector(destination: destination) { [weak self] succeeded in
                guard let self else { return }
                self.closePassiveListener()
                self.reply(context, succeeded ? 226 : 550, succeeded ? "Transfer complete" : "Write failed")
            }
            _ = channel.pipeline.addHandler(collector)
        }
    }

    private func closePassiveListener() {
        passiveListener?.close(promise: nil)
        passiveListener = nil
        passiveConnection = nil
    }

    // MARK: - Replies and paths

    private func perform(_ context: ChannelHandlerContext, _ work: () throws -> Void) {
        do {
            try work()
            reply(context, 250, "OK")
        } catch {
            reply(context, 550, "Failed")
        }
    }

    private func reply(_ context: ChannelHandlerContext, _ code: Int, _ text: String) {
        var buffer = context.channel.allocator.buffer(capacity: text.utf8.count + 8)
        buffer.writeString("\(code) \(text)\r\n")
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
    }

    private func replyLines(_ context: ChannelHandlerContext, _ code: Int, _ lines: [String]) {
        var text = ""
        for (index, line) in lines.enumerated() {
            text += index == lines.count - 1 ? "\(code) \(line)\r\n" : "\(code)-\(line)\r\n"
        }
        var buffer = context.channel.allocator.buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
    }

    private func normalized(_ path: String) -> String {
        ServerConfig.normalizedRemotePath(path.isEmpty ? workingDirectory : path)
    }

    private func localURL(for path: String) -> URL {
        let resolved = normalized(path)
        return root.appendingPathComponent(String(resolved.dropFirst()))
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter
    }()

    private static let listFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MMM d HH:mm"
        return formatter
    }()
}

/// Writes an upload to disk as it arrives and reports once the client closes.
private final class UploadCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let destination: URL
    private let completion: (Bool) -> Void
    private var received = Data()

    init(destination: URL, completion: @escaping (Bool) -> Void) {
        self.destination = destination
        self.completion = completion
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        received.append(contentsOf: unwrapInboundIn(data).readableBytesView)
    }

    func channelInactive(context: ChannelHandlerContext) {
        completion((try? received.write(to: destination)) != nil)
        context.fireChannelInactive()
    }
}

/// Counts what one download managed to send, across the event loop that
/// writes it and the test that reads it afterwards.
final class TransferredBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0

    var count: Int { lock.withLock { bytes } }

    func add(_ amount: Int) {
        lock.withLock { bytes += amount }
    }

    func reset() {
        lock.withLock { bytes = 0 }
    }
}
