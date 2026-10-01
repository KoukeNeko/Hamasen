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
    private let receivedListings: ReceivedCommands
    /// Ways to make the server misbehave, for the tests of how a client copes.
    public let behavior: FTPServerBehavior

    /// How many bytes of the last download the server managed to send.
    ///
    /// A client that stops early leaves this short of the file, which is the
    /// only way from outside to tell a ranged read that stopped from one that
    /// read everything and discarded the rest.
    public var bytesSentInLastDownload: Int { transferred.count }

    /// Every LIST the server has been sent, in order and as sent, so a test
    /// can tell which form of the command a listing took and how many.
    public var listCommands: [String] { receivedListings.lines }

    private init(
        port: Int,
        rootDirectory: URL,
        channel: Channel,
        transferred: TransferredBytes,
        receivedListings: ReceivedCommands,
        behavior: FTPServerBehavior
    ) {
        self.port = port
        self.rootDirectory = rootDirectory
        self.channel = channel
        self.transferred = transferred
        self.receivedListings = receivedListings
        self.behavior = behavior
    }

    /// - Parameter preferredPort: a fixed port, for a server someone is
    ///   going to connect to by hand. Zero picks a free one, which is what
    ///   tests want so they can run side by side.
    public static func start(
        advertisingMLSD: Bool = true,
        advertisingMLST: Bool = true,
        preferredPort: Int = 0
    ) async throws -> TestFTPServer {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

        let transferred = TransferredBytes()
        let receivedListings = ReceivedCommands()
        let behavior = FTPServerBehavior()
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
                                    advertisesMLST: advertisingMLST,
                                    transferred: transferred,
                                    receivedListings: receivedListings,
                                    behavior: behavior
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
                    transferred: transferred,
                    receivedListings: receivedListings,
                    behavior: behavior
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
    private let advertisesMLST: Bool
    private let transferred: TransferredBytes
    private let receivedListings: ReceivedCommands
    private let behavior: FTPServerBehavior
    private var isAuthenticated = false
    private var workingDirectory = "/"
    private var renameSource: String?
    private var restartOffset: Int64 = 0
    /// The listener opened by PASV/EPSV, waiting for the client to connect.
    private var passiveListener: Channel?
    private var passiveConnection: EventLoopFuture<Channel>?
    /// Completes `passiveConnection`; dropped once the client has connected.
    private var passiveAcceptor: EventLoopPromise<Channel>?

    init(
        root: URL,
        advertisesMLSD: Bool,
        advertisesMLST: Bool,
        transferred: TransferredBytes,
        receivedListings: ReceivedCommands,
        behavior: FTPServerBehavior
    ) {
        self.root = root
        self.advertisesMLSD = advertisesMLSD
        self.advertisesMLST = advertisesMLST
        self.transferred = transferred
        self.receivedListings = receivedListings
        self.behavior = behavior
    }

    func channelActive(context: ChannelHandlerContext) {
        reply(context, 220, "Test FTP ready")
    }

    func channelInactive(context: ChannelHandlerContext) {
        closePassiveListener()
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let line = unwrapInboundIn(data)
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let command = String(parts.first ?? "").uppercased()
        let argument = parts.count > 1 ? String(parts[1]) : ""
        if command == "LIST" { receivedListings.append(line) }

        // Says nothing, as a server that has hung would.
        if behavior.unresponsiveCommands.contains(command) { return }

        switch command {
        case "USER":
            reply(context, argument == TestFTPServer.username ? 331 : 530, "Need password")
        case "PASS":
            isAuthenticated = argument == TestFTPServer.password
            reply(context, isAuthenticated ? 230 : 530, isAuthenticated ? "Logged in" : "Not logged in")
        case "FEAT":
            var features = [" SIZE", " MDTM", " UTF8", " EPSV", " REST STREAM"]
            if advertisesMLSD { features.insert(" MLSD", at: 0) }
            if advertisesMLST { features.insert(" MLST type*;size*;modify*;", at: 0) }
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
        // A name the account may not touch: it is in the listing, and every
        // command on it draws the same 550 a missing file does.
        if Self.deniableCommands.contains(command), behavior.deniedNames.contains(lastComponent(of: argument)) {
            return fail(context, "Permission denied")
        }

        switch command {
        case "CWD":
            let url = followedURL(for: argument)
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if exists && isDirectory.boolValue {
                workingDirectory = normalized(argument)
                reply(context, 250, "OK")
            } else {
                fail(context, "No such directory")
            }
        case "SIZE":
            let attributes = try? FileManager.default.attributesOfItem(atPath: followedURL(for: argument).path)
            if let size = attributes?[.size] as? NSNumber {
                reply(context, 213, "\(size.int64Value)")
            } else {
                fail(context, "No such file")
            }
        case "MDTM":
            let attributes = try? FileManager.default.attributesOfItem(atPath: followedURL(for: argument).path)
            if let date = attributes?[.modificationDate] as? Date {
                reply(context, 213, Self.timestampFormatter.string(from: date))
            } else {
                fail(context, "No such file")
            }
        case "MLST":
            sendStatus(argument, context)
        case "EPSV", "PASV":
            openPassiveListener(command, context)
        case "REST":
            restartOffset = Int64(argument) ?? 0
            reply(context, 350, "Restarting at \(restartOffset)")
        case "MLSD":
            sendListing(argument, machineReadable: true, showingDotFiles: true, context)
        case "LIST":
            // Options come before the path, as most servers take them; one
            // that takes none reads "-a" as part of a name and finds nothing.
            if argument.hasPrefix("-"), behavior.takeListOptionFailure() {
                return reply(context, 450, "Try again later")
            }
            var path = argument
            var showsDotFiles = !behavior.hidesDotFiles
            if !behavior.refusesListOptions, argument.hasPrefix("-") {
                let parts = argument.split(separator: " ", maxSplits: 1)
                if parts[0].contains("a") { showsDotFiles = true }
                path = parts.count > 1 ? String(parts[1]) : ""
            }
            sendListing(path, machineReadable: false, showingDotFiles: showsDotFiles, context)
        case "RETR":
            sendFile(argument, context)
        case "STOR":
            if let refusal = behavior.storeRefusal { return reply(context, refusal.code, refusal.text) }
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
            // rmdir(2), as a real server calls it: a directory with anything
            // left in it stays.
            if rmdir(localURL(for: argument).path) == 0 {
                reply(context, 250, "OK")
            } else {
                fail(context, "Remove directory operation failed")
            }
        case "RNFR":
            guard describe(localURL(for: argument)) != nil else { return fail(context, "No such file") }
            renameSource = argument
            reply(context, 350, "Ready for RNTO")
        case "RNTO":
            guard let source = renameSource else { return reply(context, 503, "RNFR first") }
            renameSource = nil
            if behavior.rejectsRename { return fail(context, "Rename refused") }
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
        closePassiveListener()
        let accepted = context.eventLoop.makePromise(of: Channel.self)
        passiveConnection = accepted.futureResult
        passiveAcceptor = accepted

        ServerBootstrap(group: context.eventLoop)
            .childChannelInitializer { [weak self] channel in
                // A command that never used the connection leaves its promise
                // to be failed when the listener closes; a second client
                // finds none waiting.
                if let promise = self?.passiveAcceptor {
                    self?.passiveAcceptor = nil
                    promise.succeed(channel)
                }
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
        beginTransfer(pending, context, "Opening data connection") { [weak self] channel in
            // Never sends a byte or closes, as a server that hung mid-transfer.
            guard let self, !self.behavior.stallsDataTransfers else { return }
            self.sendChunk(of: body, from: 0, over: channel, context)
        }
    }

    /// Says 150 and hands over the data connection. Like vsftpd, the server
    /// can wait to say it until the client has connected; a client that
    /// waits for the 150 before connecting then never gets one.
    private func beginTransfer(
        _ pending: EventLoopFuture<Channel>,
        _ context: ChannelHandlerContext,
        _ text: String,
        _ transfer: @escaping (Channel) -> Void
    ) {
        if behavior.repliesAfterDataAccept {
            pending.whenSuccess { [weak self] channel in
                self?.reply(context, 150, text)
                transfer(channel)
            }
        } else {
            reply(context, 150, text)
            pending.whenSuccess(transfer)
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
            guard !behavior.withholdsCompletionReply else { return }
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
                let delay = self.behavior.chunkDelayMilliseconds
                if delay > 0 {
                    context.eventLoop.scheduleTask(in: .milliseconds(Int64(delay))) {
                        self.sendChunk(of: body, from: end, over: channel, context)
                    }
                } else {
                    self.sendChunk(of: body, from: end, over: channel, context)
                }
            case .failure:
                // The client closed before this finished, which is what a
                // ranged read looks like from here.
                self.closePassiveListener()
                guard !self.behavior.withholdsCompletionReply else { return }
                self.reply(context, 426, "Connection closed; transfer aborted")
            }
        }
    }

    /// What one directory entry looks like to the listing commands.
    private struct Entry {
        let isDirectory: Bool
        /// Where a symbolic link points; nil for anything else.
        let linkTarget: String?
        let size: Int64
        let modified: Date
    }

    /// Looks at the entry itself, so a link is described as a link.
    private func describe(_ url: URL) -> Entry? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let type = attributes[.type] as? FileAttributeType
        return Entry(
            isDirectory: type == .typeDirectory,
            linkTarget: type == .typeSymbolicLink
                ? try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) : nil,
            size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            modified: (attributes[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
        )
    }

    private func machineFacts(_ entry: Entry) -> String {
        let type = entry.linkTarget.map { "OS.unix=slink:\($0)" } ?? (entry.isDirectory ? "dir" : "file")
        return "type=\(type);size=\(entry.size);modify=\(Self.timestampFormatter.string(from: entry.modified));"
    }

    private func sendListing(
        _ argument: String, machineReadable: Bool, showingDotFiles: Bool, _ context: ChannelHandlerContext
    ) {
        let directory = localURL(for: argument)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            guard !machineReadable else { return fail(context, "No such directory") }
            switch behavior.missingListingAnswer {
            case .notFound: return fail(context, "No such directory")
            case .transientFailure: return reply(context, 450, "No such directory")
            case .emptyListing: return sendOverDataConnection(Data(), context)
            }
        }
        let body = names.sorted().compactMap { name -> String? in
            if !showingDotFiles, name.hasPrefix(".") { return nil }
            guard let entry = describe(directory.appendingPathComponent(name)) else { return nil }
            if machineReadable {
                return "\(machineFacts(entry)) \(name)"
            }
            let kind = entry.linkTarget != nil ? "l" : (entry.isDirectory ? "d" : "-")
            let shownName = entry.linkTarget.map { "\(name) -> \($0)" } ?? name
            return "\(kind)rw-r--r--   1 owner group \(entry.size) "
                + "\(Self.listFormatter.string(from: entry.modified)) \(shownName)"
        }.joined(separator: "\r\n")
        sendOverDataConnection(Data((body + "\r\n").utf8), context)
    }

    /// MLST: the same facts as an MLSD line, for one item, on the control
    /// connection. Its lines carry no reply code, as RFC 3659 has it.
    private func sendStatus(_ argument: String, _ context: ChannelHandlerContext) {
        guard let entry = describe(localURL(for: argument)) else { return fail(context, "No such file") }
        var buffer = context.channel.allocator.buffer(capacity: 128)
        buffer.writeString("250-Listing \(argument)\r\n \(machineFacts(entry)) \(argument)\r\n250 End\r\n")
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
    }

    private func sendFile(_ argument: String, _ context: ChannelHandlerContext) {
        guard var contents = FileManager.default.contents(atPath: localURL(for: argument).path) else {
            return fail(context, "No such file")
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
        beginTransfer(pending, context, "Ready to receive") { [weak self] channel in
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
        passiveAcceptor?.fail(ChannelError.ioOnClosedChannel)
        passiveAcceptor = nil
        passiveConnection = nil
    }

    // MARK: - Replies and paths

    private func perform(_ context: ChannelHandlerContext, _ work: () throws -> Void) {
        do {
            try work()
            reply(context, 250, "OK")
        } catch {
            fail(context, "Failed")
        }
    }

    /// The 550 a missing or refused item draws. A server's wording is its
    /// own, which is what `genericFailureText` stands in for.
    private func fail(_ context: ChannelHandlerContext, _ text: String) {
        reply(context, 550, behavior.genericFailureText ?? text)
    }

    private static let deniableCommands: Set<String> = [
        "CWD", "SIZE", "MDTM", "MLST", "MLSD", "LIST", "RETR", "DELE", "RMD", "RNFR",
    ]

    private func lastComponent(of path: String) -> String {
        String(normalized(path).split(separator: "/").last ?? "")
    }

    /// The file a path leads to once links are followed, which is what SIZE,
    /// MDTM and CWD answer about.
    private func followedURL(for path: String) -> URL {
        localURL(for: path).resolvingSymlinksInPath()
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

/// Commands as the client sent them, recorded on the event loop that reads
/// them and read by the test afterwards.
final class ReceivedCommands: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [String] = []

    var lines: [String] { lock.withLock { received } }

    func append(_ line: String) {
        lock.withLock { received.append(line) }
    }
}

/// Faults a test can switch on while a server is running.
public final class FTPServerBehavior: @unchecked Sendable {
    private let lock = NSLock()
    private var unresponsive: Set<String> = []
    private var genericText: String?
    private var denied: Set<String> = []
    private var chunkDelay = 0
    private var stalls = false
    private var withholds = false
    private var rejectsRenames = false
    private var repliesLate = false
    private var storeReply: (code: Int, text: String)?
    private var hidesDots = false
    private var refusesOptions = false
    private var optionFailures = 0
    private var missingListing = MissingListingAnswer.notFound

    /// What LIST says about a directory that is not there.
    public enum MissingListingAnswer: Sendable {
        /// 550, as most servers answer.
        case notFound
        /// 450, as though the failure would pass.
        case transientFailure
        /// An empty listing closed with 226, from servers that take the
        /// argument for a pattern that matched nothing.
        case emptyListing
    }

    /// Commands the server reads and never answers.
    public var unresponsiveCommands: Set<String> {
        get { lock.withLock { unresponsive } }
        set { lock.withLock { unresponsive = newValue } }
    }

    /// The text of every 550, in place of the usual English.
    public var genericFailureText: String? {
        get { lock.withLock { genericText } }
        set { lock.withLock { genericText = newValue } }
    }

    /// Names that exist but that every command on draws a 550 for.
    public var deniedNames: Set<String> {
        get { lock.withLock { denied } }
        set { lock.withLock { denied = newValue } }
    }

    /// Pause between the pieces of a download.
    public var chunkDelayMilliseconds: Int {
        get { lock.withLock { chunkDelay } }
        set { lock.withLock { chunkDelay = newValue } }
    }

    /// Opens a download and then sends nothing at all.
    public var stallsDataTransfers: Bool {
        get { lock.withLock { stalls } }
        set { lock.withLock { stalls = newValue } }
    }

    /// Ends a download's data connection but never sends the 226 or 426.
    public var withholdsCompletionReply: Bool {
        get { lock.withLock { withholds } }
        set { lock.withLock { withholds = newValue } }
    }

    /// Sends a transfer's 150 only after the client has connected to the data
    /// port, as vsftpd does.
    public var repliesAfterDataAccept: Bool {
        get { lock.withLock { repliesLate } }
        set { lock.withLock { repliesLate = newValue } }
    }

    /// Every RNTO fails.
    public var rejectsRename: Bool {
        get { lock.withLock { rejectsRenames } }
        set { lock.withLock { rejectsRenames = newValue } }
    }

    /// The reply STOR draws in place of accepting the upload.
    public var storeRefusal: (code: Int, text: String)? {
        get { lock.withLock { storeReply } }
        set { lock.withLock { storeReply = newValue } }
    }

    /// LIST leaves out names that start with a dot unless given -a, as
    /// vsftpd does.
    public var hidesDotFiles: Bool {
        get { lock.withLock { hidesDots } }
        set { lock.withLock { hidesDots = newValue } }
    }

    /// LIST takes no options, so "LIST -a /path" names a directory that is
    /// not there.
    public var refusesListOptions: Bool {
        get { lock.withLock { refusesOptions } }
        set { lock.withLock { refusesOptions = newValue } }
    }

    /// LIST commands with options to answer with a 450 before taking them,
    /// as a server that supports -a but was briefly busy does.
    public var listOptionFailures: Int {
        get { lock.withLock { optionFailures } }
        set { lock.withLock { optionFailures = newValue } }
    }

    func takeListOptionFailure() -> Bool {
        lock.withLock {
            guard optionFailures > 0 else { return false }
            optionFailures -= 1
            return true
        }
    }

    /// How LIST answers for a directory that is not there — which, with
    /// `refusesListOptions`, is also how it answers "LIST -a /path".
    public var missingListingAnswer: MissingListingAnswer {
        get { lock.withLock { missingListing } }
        set { lock.withLock { missingListing = newValue } }
    }
}
