import Foundation
import NIOCore
import NIOPosix

/// One transfer's data connection.
///
/// FTP moves bytes over a second connection opened per transfer, and a
/// transfer is only done when two things have both happened: the data
/// connection has closed and the control channel has sent its completion
/// reply. Waiting for either alone reports success on a truncated file.
enum FTPDataConnection {
    /// Opens the connection the server asked for and reads until it closes.
    ///
    /// - Parameter receive: called with each chunk as it arrives, on the
    ///   channel's event loop, so a large file need never be held whole.
    static func receive(
        at address: FTPPassiveAddress,
        fallbackHost: String,
        group: EventLoopGroup,
        timeoutSeconds: Int,
        into receive: @escaping @Sendable (ByteBuffer) throws -> Void
    ) async throws {
        let handler = FTPDataReceiver(receive: receive)
        let channel = try await open(address, fallbackHost, group, timeoutSeconds) { channel in
            try channel.pipeline.syncOperations.addHandler(handler)
        }
        try await handler.finished(on: channel.eventLoop).get()
    }

    /// Everything the server sends, for the transfers that are small by
    /// nature: directory listings and byte ranges.
    static func receiveAll(
        at address: FTPPassiveAddress,
        fallbackHost: String,
        group: EventLoopGroup,
        timeoutSeconds: Int
    ) async throws -> Data {
        let collected = CollectedBytes()
        try await receive(
            at: address,
            fallbackHost: fallbackHost,
            group: group,
            timeoutSeconds: timeoutSeconds
        ) { buffer in
            collected.append(buffer)
        }
        return collected.data
    }

    /// Sends a local file and closes, which is how the server knows the
    /// upload has ended.
    static func send(
        contentsOf fileURL: URL,
        at address: FTPPassiveAddress,
        fallbackHost: String,
        group: EventLoopGroup,
        timeoutSeconds: Int
    ) async throws {
        let channel = try await open(address, fallbackHost, group, timeoutSeconds) { _ in }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: uploadChunkSize), !chunk.isEmpty {
            var buffer = channel.allocator.buffer(capacity: chunk.count)
            buffer.writeBytes(chunk)
            try await channel.writeAndFlush(buffer)
        }
        try await channel.close()
    }

    /// Read and written in pieces so an upload's memory use does not follow
    /// the file's size.
    private static let uploadChunkSize = 64 * 1024

    private static func open(
        _ address: FTPPassiveAddress,
        _ fallbackHost: String,
        _ group: EventLoopGroup,
        _ timeoutSeconds: Int,
        _ configure: @escaping @Sendable (Channel) throws -> Void
    ) async throws -> Channel {
        // EPSV names only a port: the data connection goes to the host the
        // commands already go to, which is also the answer that survives NAT
        // when PASV reports an address the server cannot know is wrong.
        let host = address.host ?? fallbackHost
        return try await ClientBootstrap(group: group)
            .connectTimeout(.seconds(Int64(timeoutSeconds)))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try configure(channel) }
            }
            .connect(host: host, port: address.port)
            .get()
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
    private var completion: EventLoopPromise<Void>?
    private var outcome: Result<Void, Error>?

    init(receive: @escaping @Sendable (ByteBuffer) throws -> Void) {
        self.receive = receive
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        do {
            try receive(unwrapInboundIn(data))
        } catch {
            finish(.failure(error))
            context.close(promise: nil)
        }
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
