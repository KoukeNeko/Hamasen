import Foundation

/// One reply from an FTP control connection.
///
/// A reply is a three-digit code and some text, but it may arrive as several
/// lines: `220-first`, more lines, then `220 last`. The hyphen after the code
/// is what marks a line as "more to come", and only a line whose code matches
/// the opening one closes the reply — text inside may otherwise look like a
/// code and end it early.
public struct FTPResponse: Equatable, Sendable {
    public let code: Int
    /// Every line's text, in order, without the codes.
    public let lines: [String]

    public var text: String { lines.joined(separator: "\n") }

    public init(code: Int, lines: [String]) {
        self.code = code
        self.lines = lines
    }

    /// What the leading digit means, which is all most callers need.
    public var isPositiveCompletion: Bool { (200..<300).contains(code) }
    public var isPositivePreliminary: Bool { (100..<200).contains(code) }
    public var isPositiveIntermediate: Bool { (300..<400).contains(code) }
    public var isTransientFailure: Bool { (400..<500).contains(code) }
    public var isPermanentFailure: Bool { (500..<600).contains(code) }
    public var isFailure: Bool { isTransientFailure || isPermanentFailure }
}

/// Assembles replies from the lines a control connection delivers.
///
/// Kept apart from the connection so the rule about multi-line replies — the
/// part that is easy to get wrong and impossible to see going wrong — can be
/// tested without a socket.
public struct FTPResponseAccumulator: Sendable {
    private var pendingCode: Int?
    private var pendingLines: [String] = []

    public init() {}

    /// Feeds one line, and returns a reply once one is complete.
    public mutating func accept(_ line: String) -> FTPResponse? {
        let line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))

        guard let (code, separator, text) = Self.split(line) else {
            // A continuation line need not start with a code at all.
            if pendingCode != nil { pendingLines.append(line) }
            return nil
        }

        if let openingCode = pendingCode {
            pendingLines.append(text)
            // Only the code the reply opened with can close it.
            guard code == openingCode, separator == " " else { return nil }
            let response = FTPResponse(code: openingCode, lines: pendingLines)
            pendingCode = nil
            pendingLines = []
            return response
        }

        guard separator == " " else {
            pendingCode = code
            pendingLines = [text]
            return nil
        }
        return FTPResponse(code: code, lines: [text])
    }

    /// Splits "250-text" into its code, separator and text.
    private static func split(_ line: String) -> (code: Int, separator: Character, text: String)? {
        guard line.count >= 4 else { return nil }
        let digits = line.prefix(3)
        guard digits.allSatisfy(\.isNumber), let code = Int(digits) else { return nil }
        let separator = line[line.index(line.startIndex, offsetBy: 3)]
        guard separator == " " || separator == "-" else { return nil }
        return (code, separator, String(line.dropFirst(4)))
    }
}
