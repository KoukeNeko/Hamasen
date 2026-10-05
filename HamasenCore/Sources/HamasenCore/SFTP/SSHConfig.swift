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

import Darwin
import Foundation

/// One host an OpenSSH client configuration names, with the settings a
/// connection form needs. A value the file leaves unset is nil.
public struct SSHConfigHost: Equatable, Sendable {
    public let alias: String
    public let hostName: String?
    public let port: Int?
    public let user: String?
    /// As written, "~" and all.
    public let identityFile: String?

    public init(alias: String, hostName: String?, port: Int?, user: String?, identityFile: String?) {
        self.alias = alias
        self.hostName = hostName
        self.port = port
        self.user = user
        self.identityFile = identityFile
    }
}

/// Reads `~/.ssh/config` the way ssh does for the few keywords a connection
/// form has fields for.
///
/// Every block whose patterns match an alias contributes, in file order, and
/// the first value obtained for a keyword wins, so `Host *` at the end
/// supplies defaults. `Match` blocks depend on things known only at
/// connection time and are skipped, as are `Include`d files, which the
/// sandbox has not been given.
public enum SSHConfig {
    private struct Block {
        /// nil for the lines before the first Host, which apply to every host.
        let patterns: [String]?
        var settings: [(keyword: String, value: String)] = []

        func applies(to alias: String) -> Bool {
            guard let patterns else { return true }
            var matched = false
            for pattern in patterns {
                if pattern.hasPrefix("!") {
                    if SSHConfig.matches(alias, String(pattern.dropFirst())) { return false }
                } else if SSHConfig.matches(alias, pattern) {
                    matched = true
                }
            }
            return matched
        }
    }

    /// The hosts named without wildcards, in the order they first appear.
    public static func hosts(in text: String) -> [SSHConfigHost] {
        var blocks = [Block(patterns: nil)]
        var skipping = false
        for rawLine in text.components(separatedBy: .newlines) {
            guard let (keyword, arguments) = parse(rawLine) else { continue }
            switch keyword {
            case "host":
                blocks.append(Block(patterns: arguments))
                skipping = false
            case "match":
                skipping = true
            default:
                guard !skipping, let value = arguments.first else { continue }
                blocks[blocks.count - 1].settings.append((keyword, value))
            }
        }

        var aliases: [String] = []
        for block in blocks {
            for pattern in block.patterns ?? [] where isLiteral(pattern) && !aliases.contains(pattern) {
                aliases.append(pattern)
            }
        }
        return aliases.map { alias in
            var values: [String: String] = [:]
            for block in blocks where block.applies(to: alias) {
                for setting in block.settings where values[setting.keyword] == nil {
                    values[setting.keyword] = setting.value
                }
            }
            return SSHConfigHost(
                alias: alias,
                hostName: values["hostname"].map { $0.replacingOccurrences(of: "%h", with: alias) },
                port: values["port"].flatMap(Int.init).flatMap { ServerConfig.validPortRange.contains($0) ? $0 : nil },
                user: values["user"],
                identityFile: values["identityfile"])
        }
    }

    /// A line's lowercased keyword and its arguments, or nil for a blank or
    /// comment line. ssh accepts "Keyword value" and "Keyword=value".
    private static func parse(_ line: String) -> (String, [String])? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        guard let end = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else {
            return (trimmed.lowercased(), [])
        }
        let keyword = trimmed[..<end].lowercased()
        var rest = trimmed[end...].drop(while: { $0 == " " || $0 == "\t" })
        if rest.first == "=" { rest = rest.dropFirst().drop(while: { $0 == " " || $0 == "\t" }) }
        return (keyword, arguments(in: String(rest)))
    }

    /// Splits on whitespace, keeping a double-quoted argument whole.
    private static func arguments(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quoted = false
        var hasArgument = false
        for character in text {
            if character == "\"" {
                quoted.toggle()
                hasArgument = true
            } else if !quoted && (character == " " || character == "\t") {
                if hasArgument { result.append(current) }
                current = ""
                hasArgument = false
            } else {
                current.append(character)
                hasArgument = true
            }
        }
        if hasArgument { result.append(current) }
        return result
    }

    private static func isLiteral(_ pattern: String) -> Bool {
        !pattern.contains(where: { $0 == "*" || $0 == "?" || $0 == "!" })
    }

    /// ssh's patterns: "*" and "?" wildcards, compared without case.
    fileprivate static func matches(_ alias: String, _ pattern: String) -> Bool {
        fnmatch(pattern, alias, FNM_CASEFOLD) == 0
    }
}
