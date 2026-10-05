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

/// An address as typed or pasted into a host field.
///
/// People paste whatever their NAS or provider shows them — a bare host, a
/// host and port, or a whole URL with a trailing space — and the form takes
/// the parts it needs out of it rather than refusing it.
public struct ServerAddress: Equatable, Sendable {
    public var scheme: String?
    public var host: String
    public var port: Int?
    /// "/" when the address names no path.
    public var path: String

    public init(scheme: String? = nil, host: String, port: Int? = nil, path: String = RemotePath.root) {
        self.scheme = scheme
        self.host = host
        self.port = port
        self.path = path
    }

    /// Reads an address, or nil when there is no host in it.
    ///
    /// Leading and trailing whitespace and line breaks — what a paste most
    /// often brings along — are dropped first.
    public static func parse(_ text: String) -> ServerAddress? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let hasScheme = trimmed.range(of: "://") != nil
        guard let components = URLComponents(string: hasScheme ? trimmed : "placeholder://\(trimmed)"),
              let host = components.host, !host.isEmpty
        else {
            // Not a URL at all — most likely a bare host with a character
            // URLComponents rejects; taken as typed.
            return hasScheme || trimmed.contains(" ") ? nil : ServerAddress(host: trimmed)
        }
        let path = components.percentEncodedPath.removingPercentEncoding ?? components.path
        return ServerAddress(
            scheme: hasScheme ? components.scheme?.lowercased() : nil,
            host: host,
            port: components.port.flatMap { ServerConfig.validPortRange.contains($0) ? $0 : nil },
            path: ServerConfig.normalizedRemotePath(path))
    }

    /// The URL a WebDAV connection is shown as, port left out when it is the
    /// scheme's own.
    public static func webDAVURL(for config: ServerConfig) -> String {
        let scheme = config.transferProtocol == .webdav ? "http" : "https"
        let isDefaultPort = config.port == config.transferProtocol.defaultPort
        let path = config.remotePath == RemotePath.root ? "" : config.remotePath
        return "\(scheme)://\(config.host)\(isDefaultPort ? "" : ":\(config.port)")\(path)"
    }
}
