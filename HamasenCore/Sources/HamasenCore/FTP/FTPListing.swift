import Foundation

/// Reads the directory listings FTP servers produce.
///
/// There are two, and they are not alike. `MLSD` (RFC 3659) is machine
/// readable and unambiguous; `LIST` predates any agreement and returns
/// whatever the server's directory tool prints, most often in the Unix `ls
/// -l` shape. MLSD is asked for first and this falls back to reading the
/// other, because plenty of servers still do not offer it.
public enum FTPListing {
    /// Parses an MLSD response body.
    ///
    /// Each line is `fact=value;fact=value; name`, where the name follows the
    /// first space after the facts and may itself contain spaces.
    public static func parseMachineListing(_ body: String, directory: String) -> [RemoteItem] {
        body.split(whereSeparator: \.isNewline).compactMap { line in
            machineEntry(String(line), directory: directory)
        }
    }

    private static func machineEntry(_ line: String, directory: String) -> RemoteItem? {
        guard let separator = line.firstIndex(of: " ") else { return nil }
        let name = String(line[line.index(after: separator)...])
        guard !name.isEmpty, name != ".", name != ".." else { return nil }

        var facts: [String: String] = [:]
        for fact in line[..<separator].split(separator: ";") {
            let parts = fact.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            facts[parts[0].lowercased()] = String(parts[1])
        }

        // "cdir" and "pdir" describe the directory itself and its parent.
        let type = facts["type"]?.lowercased() ?? "file"
        guard type != "cdir", type != "pdir" else { return nil }

        return RemoteItem(
            path: RemotePath.join(directory, name),
            name: name,
            kind: type == "dir" ? .directory : (type.hasPrefix("os.unix=slink") ? .symlink : .file),
            size: facts["size"].flatMap(Int64.init) ?? 0,
            modificationDate: facts["modify"].flatMap(parseTimeval)
        )
    }

    /// `20260101120000`, always UTC per RFC 3659.
    private static func parseTimeval(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = value.count > 14 ? "yyyyMMddHHmmss.SSS" : "yyyyMMddHHmmss"
        return formatter.date(from: value)
    }

    /// Parses a Unix-style `LIST` response body.
    ///
    /// - Parameter referenceDate: what "now" is when reading a date that
    ///   omits its year, which `ls` does for anything recent. Passed in so
    ///   the reading is reproducible.
    public static func parseUnixListing(
        _ body: String,
        directory: String,
        referenceDate: Date = Date()
    ) -> [RemoteItem] {
        body.split(whereSeparator: \.isNewline).compactMap { line in
            unixEntry(String(line), directory: directory, referenceDate: referenceDate)
        }
    }

    private static func unixEntry(
        _ line: String,
        directory: String,
        referenceDate: Date
    ) -> RemoteItem? {
        // permissions links owner group size month day time-or-year name
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 9, let permissions = fields.first, permissions.count >= 10 else {
            return nil
        }

        // The name is everything after the eighth field, so a name with
        // spaces survives; splitting it off by index rather than by content.
        guard let nameStart = indexAfterFields(8, in: line) else { return nil }
        var name = String(line[nameStart...])
        guard !name.isEmpty, name != ".", name != ".." else { return nil }

        let kind: RemoteItem.Kind
        switch permissions.first {
        case "d": kind = .directory
        case "l": kind = .symlink
        default: kind = .file
        }
        // "link -> target" names the target as well; only the link is an item.
        if kind == .symlink, let arrow = name.range(of: " -> ") {
            name = String(name[..<arrow.lowerBound])
        }

        return RemoteItem(
            path: RemotePath.join(directory, name),
            name: name,
            kind: kind,
            size: Int64(fields[4]) ?? 0,
            modificationDate: parseListDate(
                month: String(fields[5]),
                day: String(fields[6]),
                timeOrYear: String(fields[7]),
                referenceDate: referenceDate
            )
        )
    }

    /// Where the text after a given number of whitespace-separated fields
    /// begins, so the remainder can be taken whole.
    private static func indexAfterFields(_ count: Int, in line: String) -> String.Index? {
        var index = line.startIndex
        var seen = 0
        while seen < count {
            while index < line.endIndex, line[index] == " " { index = line.index(after: index) }
            guard index < line.endIndex else { return nil }
            while index < line.endIndex, line[index] != " " { index = line.index(after: index) }
            seen += 1
        }
        while index < line.endIndex, line[index] == " " { index = line.index(after: index) }
        return index < line.endIndex ? index : nil
    }

    /// `ls` prints a time for recent entries and a year for older ones, and
    /// never both. A time means the entry belongs to the last six months,
    /// which can fall either side of new year.
    private static func parseListDate(
        month: String,
        day: String,
        timeOrYear: String,
        referenceDate: Date
    ) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        guard let monthNumber = monthNumbers[month.lowercased()], let dayNumber = Int(day) else {
            return nil
        }

        var components = DateComponents()
        components.month = monthNumber
        components.day = dayNumber

        if timeOrYear.contains(":") {
            let parts = timeOrYear.split(separator: ":")
            components.hour = parts.first.flatMap { Int($0) }
            components.minute = parts.count > 1 ? Int(parts[1]) : 0
            let referenceYear = calendar.component(.year, from: referenceDate)
            components.year = referenceYear
            guard let candidate = calendar.date(from: components) else { return nil }
            // A date more than a day ahead of the reference belongs to last
            // year: December read in January.
            if candidate.timeIntervalSince(referenceDate) > 86_400 {
                components.year = referenceYear - 1
            }
        } else {
            components.year = Int(timeOrYear)
        }
        return calendar.date(from: components)
    }

    private static let monthNumbers: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
        "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
    ]
}
