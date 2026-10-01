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
import NIOTLS

/// One transfer's data connection.
///
/// FTP moves bytes over a second connection opened per transfer, and a
/// transfer is only done when two things have both happened: the data
/// connection has closed and the control channel has sent its completion
/// reply. Waiting for either alone reports success on a truncated file.
enum FTPDataConnection {
    /// Connects to the address the server named, and does nothing else yet.
    ///
    /// The connection is made *before* the transfer command is sent, because
    /// some servers (vsftpd) accept the data connection first and send their
    /// 1xx reply only after; waiting for that reply before connecting stalls
    /// both sides. TLS therefore waits too: servers start it on the data
    /// socket once the transfer has begun. Reading is held off in the
    /// meantime so nothing the server sends right after its reply is lost
    /// before the handlers are in place.
    static func connect(
        to address: FTPPassiveAddress,
        fallbackHost: String,
        group: EventLoopGroup,
        timeoutSeconds: Int
    ) async throws -> Channel {
        // EPSV names only a port: the data connection goes to the host the
        // commands already go to, which is also the answer that survives NAT
        // when PASV reports an address the server cannot know is wrong.
        let host = address.host ?? fallbackHost
        return try await ClientBootstrap(group: group)
            .connectTimeout(.seconds(Int64(timeoutSeconds)))
            .channelOption(ChannelOptions.autoRead, value: false)
            .connect(host: host, port: address.port)
            .get()
    }

    /// Starts TLS on the connection when the session is protected, then lets
    /// reading begin. `extra` handlers go behind it, so they see plaintext.
    ///
    /// - Parameter waitingForHandshake: returns only once TLS is up, giving
    ///   up after `timeoutSeconds`. An upload needs it: with nothing to send
    ///   it closes straight away, and a close mid-handshake fails the
    ///   server's side of it — vsftpd then gives up on the whole session,
    ///   writing its reason in plaintext over the protected control channel.
    private static func activate(
        _ channel: Channel,
        protection: FTPDataProtection,
        handlers extra: [ChannelHandler],
        waitingForHandshake: Bool = false,
        timeoutSeconds: Int = 0
    ) async throws {
        var handlers: [ChannelHandler] = []
        var handshake: EventLoopFuture<Void>?
        if case .tls(let context, let hostname) = protection {
            handlers.append(try FTPTLS.makeHandler(context: context, host: hostname))
            if waitingForHandshake {
                let waiter = HandshakeWaiter(promise: channel.eventLoop.makePromise())
                handshake = waiter.promise.futureResult
                handlers.append(waiter)
            }
        }
        try await channel.pipeline.addHandlers(handlers + extra).get()
        try await channel.setOption(ChannelOptions.autoRead, value: true).get()
        if let handshake {
            let timer = channel.eventLoop.scheduleTask(in: .seconds(Int64(timeoutSeconds))) {
                channel.close(promise: nil)
            }
            defer { timer.cancel() }
            try await handshake.get()
        }
    }

    /// Reads from a connected data channel until the server closes it.
    ///
    /// - Parameter receive: called with each chunk as it arrives, on the
    ///   channel's event loop, so a large file need never be held whole.
    ///
    /// Gives up when nothing arrives for `timeoutSeconds`, and when the
    /// calling task is cancelled.
    static func receive(
        on channel: Channel,
        timeoutSeconds: Int,
        protection: FTPDataProtection,
        stoppingAfter limit: Int? = nil,
        into receive: @escaping @Sendable (ByteBuffer) throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let handler = FTPDataReceiver(
            receive: receive,
            limit: limit,
            idleTimeout: .seconds(Int64(timeoutSeconds))
        )
        // Closing the channel is what ends the wait, and it ends it the same
        // way a finished transfer does, so the cancellation is checked again
        // afterwards rather than trusting the outcome.
        try await withTaskCancellationHandler {
            try await activate(channel, protection: protection, handlers: [handler])
            try await handler.finished(on: channel.eventLoop).get()
        } onCancel: {
            channel.close(promise: nil)
        }
        try Task.checkCancellation()
    }

    /// Everything the server sends, for the transfers that are small by
    /// nature: directory listings and byte ranges.
    static func receiveAll(
        on channel: Channel,
        timeoutSeconds: Int,
        protection: FTPDataProtection,
        stoppingAfter limit: Int? = nil
    ) async throws -> Data {
        let collected = CollectedBytes()
        try await receive(
            on: channel,
            timeoutSeconds: timeoutSeconds,
            protection: protection,
            stoppingAfter: limit
        ) { buffer in
            collected.append(buffer)
        }
        return collected.data
    }

    /// Sends a local file over a connected data channel and closes it, which
    /// is how the server knows the upload has ended.
    ///
    /// - Parameter progress: told the running total after each chunk.
    static func send(
        contentsOf fileURL: URL,
        on channel: Channel,
        timeoutSeconds: Int,
        protection: FTPDataProtection,
        progress: TransferProgress? = nil
    ) async throws {
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try await withTaskCancellationHandler {
            try await activate(
                channel, protection: protection, handlers: [],
                waitingForHandshake: true, timeoutSeconds: timeoutSeconds)
            var sent: Int64 = 0
            while let chunk = try handle.read(upToCount: uploadChunkSize), !chunk.isEmpty {
                try Task.checkCancellation()
                var buffer = channel.allocator.buffer(capacity: chunk.count)
                buffer.writeBytes(chunk)
                try await write(buffer, to: channel, timeoutSeconds: timeoutSeconds)
                sent += Int64(chunk.count)
                progress?(sent)
            }
            try Task.checkCancellation()
            try await channel.close()
        } onCancel: {
            channel.close(promise: nil)
        }
    }

    /// A write only completes when the peer takes the bytes, so a server that
    /// stops reading stalls it for good; closing the channel is what ends it.
    private static func write(_ buffer: ByteBuffer, to channel: Channel, timeoutSeconds: Int) async throws {
        let expiry = WriteExpiry()
        let timer = channel.eventLoop.scheduleTask(in: .seconds(Int64(timeoutSeconds))) {
            expiry.mark()
            channel.close(promise: nil)
        }
        defer { timer.cancel() }
        do {
            try await channel.writeAndFlush(buffer)
        } catch {
            throw expiry.hasExpired ? FTPError.timedOut : error
        }
    }

    /// Read and written in pieces so an upload's memory use does not follow
    /// the file's size.
    private static let uploadChunkSize = 64 * 1024
}

/// Whether a transfer's bytes are protected, which follows what `PROT`
/// last agreed with the server.
enum FTPDataProtection: Sendable {
    case clear
    case tls(context: NIOSSLContext, hostname: String)
}

/// Whether a write's timer went off, read from the task that wrote.
private final class WriteExpiry: @unchecked Sendable {
    private let lock = NSLock()
    private var expired = false

    var hasExpired: Bool { lock.withLock { expired } }

    func mark() {
        lock.withLock { expired = true }
    }
}

/// Gathers a whole small transfer.
///
/// Locked rather than left to the event loop alone: the chunks arrive there,
/// but the result is read from the task that asked for it once the transfer
/// has finished.
private final class CollectedBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()

    func append(_ buffer: ByteBuffer) {
        lock.withLock { bytes.append(contentsOf: buffer.readableBytesView) }
    }

    var data: Data { lock.withLock { bytes } }
}

/// Feeds arriving bytes onwards and reports when the server has closed.
private final class FTPDataReceiver: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let receive: @Sendable (ByteBuffer) throws -> Void
    /// How many bytes are wanted, when the caller wants only some of what the
    /// server is about to send. FTP has no way to ask it to stop, so the
    /// connection is closed once enough has arrived.
    private let limit: Int?
    /// How long the connection may stay silent. A server that stalls
    /// mid-transfer neither sends nor closes, so nothing else would end it.
    private let idleTimeout: TimeAmount
    private var idleTimer: Scheduled<Void>?
    private var received = 0
    private var completion: EventLoopPromise<Void>?
    private var outcome: Result<Void, Error>?

    init(receive: @escaping @Sendable (ByteBuffer) throws -> Void, limit: Int?, idleTimeout: TimeAmount) {
        self.receive = receive
        self.limit = limit
        self.idleTimeout = idleTimeout
    }

    func handlerAdded(context: ChannelHandlerContext) {
        armIdleTimer(context)
    }

    private func armIdleTimer(_ context: ChannelHandlerContext) {
        idleTimer?.cancel()
        let channel = context.channel
        idleTimer = context.eventLoop.scheduleTask(in: idleTimeout) { [self] in
            finish(.failure(FTPError.timedOut))
            channel.close(promise: nil)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        armIdleTimer(context)
        var buffer = unwrapInboundIn(data)
        if let limit {
            let remaining = limit - received
            guard remaining > 0 else { return finishAndClose(context) }
            if buffer.readableBytes > remaining {
                buffer = buffer.readSlice(length: remaining) ?? buffer
            }
        }
        received += buffer.readableBytes

        do {
            try receive(buffer)
        } catch {
            finish(.failure(error))
            context.close(promise: nil)
            return
        }
        // Enough is enough: reading on to the end of the file is what the
        // caller asked for a range instead of.
        if let limit, received >= limit { finishAndClose(context) }
    }

    private func finishAndClose(_ context: ChannelHandlerContext) {
        finish(.success(()))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        // A closed data connection is how the end of a transfer is announced.
        finish(.success(()))
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(.failure(error))
        context.close(promise: nil)
    }

    private func finish(_ result: Result<Void, Error>) {
        guard outcome == nil else { return }
        idleTimer?.cancel()
        outcome = result
        completion?.completeWith(result)
    }

    /// Completes once the server has closed the connection.
    func finished(on eventLoop: EventLoop) -> EventLoopFuture<Void> {
        eventLoop.flatSubmit {
            if let outcome = self.outcome {
                return eventLoop.makeCompletedFuture(outcome)
            }
            let promise = eventLoop.makePromise(of: Void.self)
            self.completion = promise
            return promise.futureResult
        }
    }
}

/// Tells when the data connection's TLS handshake has finished, or that the
/// connection ended first.
private final class HandshakeWaiter: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = NIOAny

    let promise: EventLoopPromise<Void>
    private var isSettled = false

    init(promise: EventLoopPromise<Void>) {
        self.promise = promise
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted = event { settle(.success(())) }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        settle(.failure(error))
        context.fireErrorCaught(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        settle(.failure(ChannelError.ioOnClosedChannel))
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        settle(.failure(ChannelError.ioOnClosedChannel))
    }

    private func settle(_ result: Result<Void, Error>) {
        guard !isSettled else { return }
        isSettled = true
        promise.completeWith(result)
    }
}
