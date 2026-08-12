import Foundation

/// Expands a requested byte range to the alignment the File Provider system
/// asks for when fetching part of a file.
///
/// The system requires the offset to be a multiple of the alignment and the
/// length to be a multiple too, except for the final chunk of a file, which
/// may be short.
public enum ByteRangeAlignment {
    public struct Range: Equatable, Sendable {
        public let offset: Int64
        public let length: Int

        public var isEmpty: Bool { length == 0 }
    }

    public static func align(
        offset requestedOffset: Int64,
        length requestedLength: Int,
        alignment: Int,
        fileSize: Int64
    ) -> Range {
        let alignment = Int64(max(alignment, 1))
        let start = max(requestedOffset, 0)
        guard start < fileSize else { return Range(offset: fileSize, length: 0) }

        let alignedStart = (start / alignment) * alignment
        let requestedEnd = start + Int64(max(requestedLength, 0))
        let alignedEnd = ((requestedEnd + alignment - 1) / alignment) * alignment
        // Always hand back at least one aligned block, and never read past the
        // end of the file.
        let end = min(max(alignedEnd, alignedStart + alignment), fileSize)
        return Range(offset: alignedStart, length: Int(end - alignedStart))
    }
}
