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

/// Builds the service for a server's protocol. The single place where the
/// protocol-to-implementation mapping lives, so the app and the File Provider
/// extension can never disagree about it.
public enum RemoteFileServiceFactory {
    public static func makeService(
        for config: ServerConfig,
        credentials: ServerCredentials,
        connectTimeoutSeconds: Int = AppSettings.connectTimeoutSeconds()
    ) -> any RemoteFileService {
        switch config.transferProtocol {
        case .sftp:
            return SFTPFileService(
                config: config,
                credentials: credentials,
                connectTimeoutSeconds: connectTimeoutSeconds,
                hostKeyPolicy: hostKeyPolicy()
            )
        case .webdav, .webdavs:
            return WebDAVFileService(
                config: config,
                credentials: credentials,
                connectTimeoutSeconds: connectTimeoutSeconds
            )
        case .ftp, .ftps:
            return FTPFileService(
                config: config,
                credentials: credentials,
                connectTimeoutSeconds: connectTimeoutSeconds
            )
        }
    }

    /// Where SSH host keys are remembered.
    ///
    /// A record that cannot be opened refuses connections instead of letting
    /// them through unchecked: the app and the extension both hold the App
    /// Group entitlement, so failing to open it means something is wrong
    /// enough that trusting whatever answers would be the worse choice.
    private static func hostKeyPolicy() -> HostKeyPolicy {
        do {
            return .trustOnFirstUse(try KnownHostsStore())
        } catch {
            return .unverifiable(reason: error.localizedDescription)
        }
    }
}
