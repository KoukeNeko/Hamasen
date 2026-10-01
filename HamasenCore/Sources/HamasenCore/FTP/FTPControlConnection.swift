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
    /// How long a reply may take before the server is taken to be gone. A
    /// server that goes silent never closes the socket, so without this the
    /// caller waits forever.
    private let replyTimeout: TimeAmount

    private init(channel: Channel, responses: FTPResponseHandler, replyTimeout: TimeAmount) {
        self.channel = channel
        self.responses = responses
        self.replyTimeout = replyTimeout
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
        trustRoots: NIOSSLTrustRoots = .default,
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

        let connection = FTPControlConnection(
            channel: channel,
            responses: responses,
            replyTimeout: .seconds(Int64(timeoutSeconds))
        )
        let greeting: FTPResponse
        do {
            greeting = try await connection.nextReply(timeout: connection.replyTimeout)
        } catch {
            await connection.close()
            throw RemoteFileServiceError.connectionFailed(underlying: String(describing: error))
        }
        guard greeting.isPositiveCompletion else {
            try? await channel.close()
            throw RemoteFileServiceError.connectionFailed(underlying: greeting.text)
        }
        if tls == .explicit {
            do {
                try await connection.startTLS(host: host, trustRoots: trustRoots)
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
    private func startTLS(host: String, trustRoots: NIOSSLTrustRoots) async throws {
        let response = try await send("AUTH TLS")
        guard response.isPositiveCompletion else {
            throw FTPError.commandFailed(command: "AUTH", response: response)
        }
        // The handler is built on the event loop that will own it, rather
        // than here and handed over: an SSL handler is not Sendable, and
        // passing one across an isolation boundary is an error under the
        // Swift 6 language mode. Only the hostname crosses.
        let hostname = host
        try await channel.eventLoop.submit {
            let handler = try FTPTLS.makeHandler(context: FTPTLS.makeContext(trustRoots: trustRoots), host: hostname)
            // At the head, so bytes are decrypted before anything tries to
            // read lines out of them.
            try self.channel.pipeline.syncOperations.addHandler(handler, position: .first)
        }.get()
    }

    /// Sends a command and returns the reply it draws.
    ///
    /// - Parameter redactingArgument: keeps a password out of the log while
    ///   still recording that the command was sent.
    @discardableResult
    func send(_ command: String, redactingArgument: Bool = false) async throws -> FTPResponse {
        // A line break inside a path would end the command early and let the
        // rest run as a second one. Scalars, because "\r\n" is one Character.
        guard !command.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" }) else {
            throw FTPError.invalidCommand
        }
        Self.log.debug("→ \(redactingArgument ? String(command.prefix(4)) + "…" : command)")
        var buffer = channel.allocator.buffer(capacity: command.utf8.count + 2)
        buffer.writeString(command + Self.lineEnding)
        try await channel.writeAndFlush(buffer)
        let response = try await nextReply(timeout: replyTimeout)
        Self.log.debug("← \(response.code) \(response.lines.first ?? "")")
        return response
    }

    /// Sends a command and fails unless the reply says it worked.
    @discardableResult
    func expect(_ command: String, redactingArgument: Bool = false) async throws -> FTPResponse {
        let response = try await send(command, redactingArgument: redactingArgument)
        guard !response.isFailure else {
            throw FTPError.commandFailed(command: FTPError.name(of: command), response: response)
        }
        return response
    }

    /// The reply that closes a transfer, read once the data connection ends.
    func awaitCompletion() async throws -> FTPResponse {
        try await nextReply(timeout: replyTimeout)
    }

    /// A reply that has not arrived in time will arrive later, in front of
    /// the reply to whatever is sent next. There is no way to tell them
    /// apart afterwards, so the connection is closed rather than kept.
    private func nextReply(timeout: TimeAmount) async throws -> FTPResponse {
        do {
            return try await responses.nextResponse(on: channel.eventLoop, timeout: timeout).get()
        } catch let error as FTPError {
            if case .timedOut = error { await close() }
            throw error
        }
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
    ///
    /// A timeout fails the whole handler rather than only this wait: the
    /// reply that never came is still owed, so nothing read afterwards can be
    /// matched to its command.
    func nextResponse(on eventLoop: EventLoop, timeout: TimeAmount) -> EventLoopFuture<FTPResponse> {
        eventLoop.flatSubmit {
            if !self.delivered.isEmpty {
                return eventLoop.makeSucceededFuture(self.delivered.removeFirst())
            }
            if let failure = self.failure {
                return eventLoop.makeFailedFuture(failure)
            }
            let promise = eventLoop.makePromise(of: FTPResponse.self)
            self.waiting.append(promise)
            let timer = eventLoop.scheduleTask(in: timeout) {
                self.fail(with: FTPError.timedOut)
            }
            promise.futureResult.whenComplete { _ in timer.cancel() }
            return promise.futureResult
        }
    }
}

/// What can go wrong that is particular to FTP, before it becomes the error
/// the rest of the app speaks.
enum FTPError: Error {
    case commandFailed(command: String, response: FTPResponse)
    case connectionClosed
    /// The server did not answer, or stopped sending data, in time.
    case timedOut
    /// A command that would have run as more than one.
    case invalidCommand
    case unreadableAddress(response: FTPResponse)

    /// The verb of a command line, which is what a failure is reported by.
    static func name(of command: String) -> String {
        String(command.split(separator: " ", maxSplits: 1).first ?? "")
    }

    /// Replies that say the session or its data connection is gone, however
    /// the command was worded: 421 closes the control connection, 425 and
    /// 426 mean a data connection could not be opened or was cut.
    var isConnectionLevel: Bool {
        switch self {
        case .connectionClosed, .timedOut: return true
        case .commandFailed(_, let response): return [421, 425, 426].contains(response.code)
        case .invalidCommand, .unreadableAddress: return false
        }
    }

    /// The service-level error this becomes, so callers see the same kinds of
    /// failure whatever protocol they are talking.
    ///
    /// Telling a missing item from a refused one needs a look at the server,
    /// which is the service's to make; this maps only what the reply alone
    /// decides.
    func asServiceError(operation: String, path: String) -> RemoteFileServiceError {
        switch self {
        case .commandFailed(_, let response):
            // 530 is "not logged in", which is what a wrong password draws.
            if response.code == 530 { return .authenticationFailed }
            if isConnectionLevel {
                return .connectionFailed(underlying: response.text)
            }
            // 553 is a name the server will not accept, which in practice is
            // a permission.
            if response.code == 553 { return .permissionDenied(operation: operation, path: path) }
            if response.code == 550, response.text.lowercased().contains("no such") {
                return .itemNotFound(path: path)
            }
            return .operationFailed(operation: operation, path: path, underlying: response.text)
        case .connectionClosed:
            return .connectionFailed(underlying: "the server closed the connection")
        case .timedOut:
            return .connectionFailed(underlying: "the server stopped responding")
        case .invalidCommand:
            return .operationFailed(
                operation: operation,
                path: path,
                underlying: "the path contains a line break"
            )
        case .unreadableAddress(let response):
            return .operationFailed(
                operation: operation,
                path: path,
                underlying: "unreadable passive-mode address: \(response.text)"
            )
        }
    }
}
