import NIOCore

/// Splits the control stream into lines.
///
/// Hand-written rather than taken from NIOExtras: it is a dozen lines, and
/// this package would otherwise carry a whole extra dependency for them.
final class FTPLineDecoder: ByteToMessageDecoder {
    typealias InboundOut = String

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        let view = buffer.readableBytesView
        guard let newline = view.firstIndex(of: UInt8(ascii: "\n")) else { return .needMoreData }

        let length = newline - view.startIndex + 1
        guard var line = buffer.readSlice(length: length) else { return .needMoreData }
        // Drop the terminator, and the carriage return before it when present.
        line.moveWriterIndex(to: line.writerIndex - 1)
        if line.readableBytesView.last == UInt8(ascii: "\r") {
            line.moveWriterIndex(to: line.writerIndex - 1)
        }
        context.fireChannelRead(wrapInboundOut(String(buffer: line)))
        return .continue
    }

    func decodeLast(
        context: ChannelHandlerContext,
        buffer: inout ByteBuffer,
        seenEOF: Bool
    ) throws -> DecodingState {
        // A final line without a terminator is still a line.
        guard buffer.readableBytes > 0, let line = buffer.readSlice(length: buffer.readableBytes) else {
            return .needMoreData
        }
        context.fireChannelRead(wrapInboundOut(String(buffer: line)))
        return .needMoreData
    }
}
