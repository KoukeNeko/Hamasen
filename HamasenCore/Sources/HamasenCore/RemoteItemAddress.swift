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

/// The URL that names an item on its server, as another client would be
/// given it: `sftp://user@host/path`, the WebDAV or S3 address, and so on.
/// It carries no secret, so it is safe to paste anywhere.
///
/// Worked out from the settings alone, without asking the server. Cloud
/// drives have no such address — an item there is reached through its web
/// page, which only their API can name.
public enum RemoteItemAddress {
    public static func url(of mountRelativePath: String, on config: ServerConfig) -> URL? {
        let absolute = RemotePath.resolve(mountRelativePath, against: config.remotePath)
        switch config.transferProtocol {
        case .sftp, .ftp, .ftps, .smb:
            return url(scheme: config.transferProtocol.rawValue, user: config.username, path: absolute, on: config)
        case .webdav, .webdavs:
            return url(scheme: config.transferProtocol.urlScheme, user: nil, path: absolute, on: config)
        case .s3:
            guard let object = try? S3ObjectKey(absolutePath: absolute) else { return nil }
            return RemoteFileServiceFactory.s3Endpoint(for: config).address(for: object)?.url
        case .googleDrive, .oneDrive, .dropbox:
            return nil
        }
    }

    /// URLComponents rejects a bare IPv6 literal; it has to be bracketed.
    public static func urlHost(for host: String) -> String {
        guard host.contains(":"), !host.hasPrefix("[") else { return host }
        return "[\(host)]"
    }

    private static func url(scheme: String?, user: String?, path: String, on config: ServerConfig) -> URL? {
        // URLComponents traps rather than failing on a port out of range.
        guard ServerConfig.validPortRange.contains(config.port) else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        if let user, !user.isEmpty { components.user = user }
        components.host = urlHost(for: config.host)
        if config.port != config.transferProtocol.defaultPort {
            components.port = config.port
        }
        components.path = path
        return components.url
    }
}
