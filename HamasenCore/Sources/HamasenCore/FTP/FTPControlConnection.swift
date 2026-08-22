import Foundation
import NIOCore
import NIOPosix
import NIOSSL

/// The command channel of an FTP session.
///
/// FTP answers once per command on this channel, with the exception that
/// shapes everything else: a transfer replies twice — once to say it has
/// begun and again when it is done, with the bytes moving over a second
/// connection in between. Sending and awaiting completion are separate calls
/// here for that reason.
actor FTPControlConnection {
    private static let lineEnding = "\r\n"
    private static let log = HamasenLog(category: "ftp")

    private let channel: Channel
    private let responses: FTPResponseHandler

    private init(channel: Channel, responses: FTPResponseHandler) {
        self.channel = channel
        self.responses = responses
    }

    /// The address the control connection is talking to, which is where a
    /// passive data connection goes when the server names no host of its own.
    var remoteHost: String? {
        channel.remoteAddress?.ipAddress
    }

    var eventLoopGroup: EventLoopGroup { channel.eventLoop }

    /// Opens the channel, reads the greeting the server sends unprompted,
    /// and upgrades to TLS before anything worth protecting is sent.
    static func connect(
        host: String,
        port: Int,
        timeoutSeconds: Int,
        tls: FTPTLSMode = .none,
        group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) async throws -> (connection: FTPControlConnection, greeting: FTPResponse) {
        let responses = FTPResponseHandler()
        let channel: Channel
        do {
            channel = try await ClientBootstrap(group: group)
                .connectTimeout(.seconds(Int64(timeoutSeconds)))
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandlers([
                            ByteToMessageHandler(FTPLineDecoder()),
                            responses,
                        ])
                    }
                }
                .connect(host: host, port: port)
                .get()
        } catch {
            throw RemoteFileServiceError.connectionFailed(underlying: String(describing: error))
        }

        let connection = FTPControlConnection(channel: channel, responses: responses)
        let greeting = try await responses.nextResponse(on: channel.eventLoop).get()
        guard greeting.isPositiveCompletion else {
            try? await channel.close()
            throw RemoteFileServiceError.connectionFailed(underlying: greeting.text)
        }
        if tls == .explicit {
            do {
                try await connection.startTLS(host: host)
            } catch {
                await connection.close()
                throw error
            }
        }
        return (connection, greeting)
    }

    /// Upgrades the control connection, which has to happen before the login
    /// rather than after it: the point is that the password never travels in
    /// the clear.
    private func startTLS(host: String) async throws {
        let response = try await send("AUTH TLS")
        guard response.isPositiveCompletion else {
            throw FTPError.commandFailed(command: "AUTH", response: response)
        }
        let handler = try FTPTLS.makeHandler(context: FTPTLS.makeContext(), host: host)
        // At the head, so bytes are decrypted before anything tries to read
        // lines out of them.
        try await channel.pipeline.addHandler(handler, position: .first)
    }

    /// Sends a command and returns the reply it draws.
    ///
    /// - Parameter redactingArgument: keeps a password out of the log while
    ///   still recording that the command was sent.
    @discardableResult
    func send(_ command: String, redactingArgument: Bool = false) async throws -> FTPResponse {
        Self.log.debug("→ \(redactingArgument ? String(command.prefix(4)) + "…" : command)")
        var buffer = channel.allocator.buffer(capacity: command.utf8.count + 2)
        buffer.writeString(command + Self.lineEnding)
        try await channel.writeAndFlush(buffer)
        let response = try await responses.nextResponse(on: channel.eventLoop).get()
        Self.log.debug("← \(response.code) \(response.lines.first ?? "")")
        return response
    }

    /// Sends a command and fails unless the reply says it worked.
    @discardableResult
    func expect(_ command: String, redactingArgument: Bool = false) async throws -> FTPResponse {
        let response = try await send(command, redactingArgument: redactingArgument)
        guard !response.isFailure else {
            throw FTPError.commandFailed(command: String(command.prefix(4)), response: response)
        }
        return response
    }

    /// The reply that closes a transfer, read once the data connection ends.
    func awaitCompletion() async throws -> FTPResponse {
        try await responses.nextResponse(on: channel.eventLoop).get()
    }

    var isActive: Bool { channel.isActive }

    func close() async {
        try? await channel.close()
    }
}

/// Turns the lines arriving on the control channel into replies, and hands
/// each to whoever is waiting.
///
/// Every field is touched on the channel's event loop and nowhere else, which
/// is what makes the unchecked conformance true rather than merely asserted.
private final class FTPResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = String

    private var accumulator = FTPResponseAccumulator()
    /// Replies that arrived before anyone asked for them, which is the normal
    /// order for the greeting and for a transfer's completion.
    private var delivered: [FTPResponse] = []
    private var waiting: [EventLoopPromise<FTPResponse>] = []
    private var failure: Error?

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard let response = accumulator.accept(unwrapInboundIn(data)) else { return }
        if waiting.isEmpty {
            delivered.append(response)
        } else {
            waiting.removeFirst().succeed(response)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        fail(with: FTPError.connectionClosed)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(with: error)
        context.close(promise: nil)
    }

    private func fail(with error: Error) {
        guard failure == nil else { return }
        failure = error
        let pending = waiting
        waiting = []
        for promise in pending { promise.fail(error) }
    }

    /// The next reply, whether it has already arrived or has yet to.
    func nextResponse(on eventLoop: EventLoop) -> EventLoopFuture<FTPResponse> {
        eventLoop.flatSubmit {
            if !self.delivered.isEmpty {
                return eventLoop.makeSucceededFuture(self.delivered.removeFirst())
            }
            if let failure = self.failure {
                return eventLoop.makeFailedFuture(failure)
            }
            let promise = eventLoop.makePromise(of: FTPResponse.self)
            self.waiting.append(promise)
            return promise.futureResult
        }
    }
}

/// What can go wrong that is particular to FTP, before it becomes the error
/// the rest of the app speaks.
enum FTPError: Error {
    case commandFailed(command: String, response: FTPResponse)
    case connectionClosed
    case unreadableAddress(response: FTPResponse)

    /// The service-level error this becomes, so callers see the same kinds of
    /// failure whatever protocol they are talking.
    func asServiceError(operation: String, path: String) -> RemoteFileServiceError {
        switch self {
        case .commandFailed(_, let response):
            // 530 is "not logged in", which is what a wrong password draws.
            // 550 covers both "no such file" and "permission denied", and
            // only the text tells them apart.
            if response.code == 530 { return .authenticationFailed }
            if response.code == 550, response.text.lowercased().contains("no such") {
                return .itemNotFound(path: path)
            }
            return .operationFailed(operation: operation, path: path, underlying: response.text)
        case .connectionClosed:
            return .connectionFailed(underlying: "the server closed the connection")
        case .unreadableAddress(let response):
            return .operationFailed(
                operation: operation,
                path: path,
                underlying: "unreadable passive-mode address: \(response.text)"
            )
        }
    }
}
