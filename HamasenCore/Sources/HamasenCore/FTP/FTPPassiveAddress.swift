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

/// Where to open the data connection, as the server describes it.
public struct FTPPassiveAddress: Equatable, Sendable {
    /// Absent when the server named only a port, which is what EPSV does:
    /// the data connection goes to the same host the commands do.
    public let host: String?
    public let port: Int

    public init(host: String?, port: Int) {
        self.host = host
        self.port = port
    }

    /// Reads a `229` reply: `Entering Extended Passive Mode (|||49152|)`.
    ///
    /// The delimiter is whatever character sits in the first position, so it
    /// is taken from the text rather than assumed to be `|`.
    public static func extendedPassive(from response: FTPResponse) -> FTPPassiveAddress? {
        guard let open = response.text.firstIndex(of: "("),
              let close = response.text[open...].firstIndex(of: ")")
        else { return nil }

        let body = response.text[response.text.index(after: open)..<close]
        guard let delimiter = body.first else { return nil }
        let fields = body.split(separator: delimiter, omittingEmptySubsequences: false)
        // (<d><d><d>port<d>) splits into four empty leading fields, the port,
        // and a trailing empty one.
        guard let port = fields.dropLast().last.flatMap({ Int($0) }), (1...65535).contains(port) else {
            return nil
        }
        return FTPPassiveAddress(host: nil, port: port)
    }

    /// Reads a `227` reply: `Entering Passive Mode (10,0,0,1,192,0)`, where
    /// the last two numbers are the port's high and low bytes.
    public static func passive(from response: FTPResponse) -> FTPPassiveAddress? {
        guard let open = response.text.lastIndex(of: "("),
              let close = response.text[open...].firstIndex(of: ")")
        else { return nil }

        let numbers = response.text[response.text.index(after: open)..<close]
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count == 6, numbers.allSatisfy({ (0...255).contains($0) }) else { return nil }

        let port = numbers[4] << 8 | numbers[5]
        guard (1...65535).contains(port) else { return nil }
        return FTPPassiveAddress(
            host: numbers[0..<4].map(String.init).joined(separator: "."),
            port: port
        )
    }
}
