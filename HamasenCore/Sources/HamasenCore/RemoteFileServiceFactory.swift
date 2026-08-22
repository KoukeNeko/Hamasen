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
