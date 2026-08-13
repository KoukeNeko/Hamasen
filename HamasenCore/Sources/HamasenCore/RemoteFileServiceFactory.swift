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
                connectTimeoutSeconds: connectTimeoutSeconds
            )
        case .webdav, .webdavs:
            return WebDAVFileService(
                config: config,
                credentials: credentials,
                connectTimeoutSeconds: connectTimeoutSeconds
            )
        }
    }
}
