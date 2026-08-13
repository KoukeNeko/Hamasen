import FileProvider
import Foundation
import HamasenCore

/// Owns one connection per server for the lifetime of the extension and
/// resolves server configurations from the shared stores.
actor ConnectionRegistry {
    enum RegistryError: Error {
        case serverConfigurationMissing(UUID)
    }

    private var services: [UUID: any RemoteFileService] = [:]

    /// Returns a connected service for the server, creating one on first use.
    func service(for serverID: UUID) async throws -> any RemoteFileService {
        if let existingService = services[serverID] {
            return existingService
        }
        let config = try Self.config(for: serverID)
        let credentials = try KeychainCredentialStore().loadCredentials(for: config)
        let service = RemoteFileServiceFactory.makeService(for: config, credentials: credentials)
        try await service.connect()
        services[serverID] = service
        return service
    }

    func shutdownAll() async {
        let activeServices = services.values
        services.removeAll()
        for service in activeServices {
            try? await service.disconnect()
        }
    }

    static func config(for serverID: UUID) throws -> ServerConfig {
        guard let config = try ServerConfigStore().server(withID: serverID) else {
            throw RegistryError.serverConfigurationMissing(serverID)
        }
        return config
    }

    /// The servers currently shown in Finder, in the app's list order.
    static func mountedConfigs() throws -> [ServerConfig] {
        let mountedIDs = try MountedServersStore().loadMountedServerIDs()
        return try ServerConfigStore().loadServers().filter { mountedIDs.contains($0.id) }
    }
}

/// Maps service-layer errors to NSFileProviderError values the system
/// understands.
enum FileProviderErrorMapper {
    static func map(_ error: Error) -> Error {
        switch error {
        case RemoteFileServiceError.itemNotFound:
            return NSFileProviderError(.noSuchItem)
        case RemoteFileServiceError.authenticationFailed:
            return NSFileProviderError(.notAuthenticated)
        case RemoteFileServiceError.connectionFailed, RemoteFileServiceError.notConnected:
            return NSFileProviderError(.serverUnreachable)
        case KeychainCredentialStore.KeychainError.itemNotFound:
            return NSFileProviderError(.notAuthenticated)
        case ConnectionRegistry.RegistryError.serverConfigurationMissing:
            return NSFileProviderError(.noSuchItem)
        default:
            return error
        }
    }
}
