import FileProvider
import Foundation
import HamasenCore

/// Owns one connection per server for the lifetime of the extension and
/// resolves server configurations from the shared stores.
actor ConnectionRegistry {
    enum RegistryError: Error {
        case serverConfigurationMissing(UUID)
    }

    /// The in-flight or completed connection per server. Storing the task
    /// rather than the service closes the window where two callers each build
    /// and connect their own service and the loser is dropped without being
    /// disconnected, leaking its session and credentials.
    private var connections: [UUID: Task<any RemoteFileService, Error>] = [:]

    /// Returns a connected service for the server, creating one on first use.
    func service(for serverID: UUID) async throws -> any RemoteFileService {
        if let existing = connections[serverID] {
            do {
                return try await existing.value
            } catch {
                // A failed attempt must not be cached, or the server would
                // stay broken until the extension restarts.
                connections[serverID] = nil
                throw error
            }
        }

        let connection = Task { () throws -> any RemoteFileService in
            let config = try Self.config(for: serverID)
            let credentials = try KeychainCredentialStore().loadCredentials(for: config)
            let service = RemoteFileServiceFactory.makeService(for: config, credentials: credentials)
            try await service.connect()
            return service
        }
        connections[serverID] = connection

        do {
            return try await connection.value
        } catch {
            connections[serverID] = nil
            throw error
        }
    }

    func shutdownAll() async {
        let pending = connections.values
        connections.removeAll()
        for connection in pending {
            guard let service = try? await connection.value else { continue }
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
        case KeychainCredentialStore.KeychainError.itemNotFound,
             RemoteFileServiceError.unsupportedCredentials,
             RemoteFileServiceError.privateKeyPassphraseRequired,
             RemoteFileServiceError.privateKeyUnreadable:
            // All of these mean "the stored credential cannot be used", which
            // is the state that makes Finder offer a sign-in affordance.
            return NSFileProviderError(.notAuthenticated)
        case ConnectionRegistry.RegistryError.serverConfigurationMissing:
            return NSFileProviderError(.noSuchItem)
        default:
            return error
        }
    }
}
