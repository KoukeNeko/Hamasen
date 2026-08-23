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
        case .s3:
            return S3FileService(
                config: config,
                credentials: credentials,
                endpoint: s3Endpoint(for: config),
                connectTimeoutSeconds: connectTimeoutSeconds,
                multipartThresholdBytes: AppSettings.s3MultipartThresholdBytes(),
                partSizeBytes: AppSettings.s3PartSizeBytes()
            )
        }
    }

    /// Unset settings are derived so the common providers work as typed:
    /// the region is written into Amazon's own hostnames and can be read
    /// back out, everything else is regionless, and only Amazon wants the
    /// bucket in the hostname. The stored values exist for the provider that
    /// does not fit that guess.
    static func s3Endpoint(for config: ServerConfig) -> S3Endpoint {
        S3Endpoint(
            scheme: S3Endpoint.scheme(forHost: config.host),
            host: config.host,
            port: config.port == config.transferProtocol.defaultPort ? nil : config.port,
            region: config.s3Region.flatMap { $0.isEmpty ? nil : $0 }
                ?? S3Endpoint.inferredRegion(forHost: config.host),
            addressingStyle: config.s3AddressingStyle
        )
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
