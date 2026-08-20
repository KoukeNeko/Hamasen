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

    /// Returns a connected service for the server, creating one on first use
    /// and replacing one whose session has since died.
    func service(for serverID: UUID) async throws -> any RemoteFileService {
        if let live = try await liveService(for: serverID) {
            return live
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

    /// The cached service, if there is one and it is still usable.
    ///
    /// A session that has gone away — an idle connection the server closed,
    /// a sleep, a network change — fails every operation with the same error
    /// from then on. Cached, it would keep the server broken until the
    /// extension restarts, which is what makes Finder report the same
    /// failure however many times the user retries.
    private func liveService(for serverID: UUID) async throws -> (any RemoteFileService)? {
        guard let existing = connections[serverID] else { return nil }

        let service: any RemoteFileService
        do {
            service = try await existing.value
        } catch {
            // A failed attempt must not be cached, or the server would
            // stay broken until the extension restarts.
            connections[serverID] = nil
            throw error
        }

        if await service.isConnected { return service }
        connections[serverID] = nil
        // Not awaited: the session is already gone, so its teardown has
        // nothing left to do for this caller, and the registry has to stay
        // answerable to every other server while it happens.
        Task { try? await service.disconnect() }
        return nil
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
        case is KeychainCredentialStore.KeychainError,
             RemoteFileServiceError.unsupportedCredentials,
             RemoteFileServiceError.privateKeyPassphraseRequired,
             RemoteFileServiceError.privateKeyUnreadable:
            // All of these mean "the stored credential cannot be used", which
            // is the state that makes Finder offer a sign-in affordance.
            return NSFileProviderError(.notAuthenticated)
        case ConnectionRegistry.RegistryError.serverConfigurationMissing:
            return NSFileProviderError(.noSuchItem)
        case RemoteFileServiceError.operationFailed:
            // Most often a session that died under the operation. Reporting
            // it as unreachable is what makes the system retry — on the
            // replacement connection — rather than treat the item as broken.
            return NSFileProviderError(.serverUnreachable)
        case is NSFileProviderError, is CocoaError:
            return error
        default:
            // The system rejects any other error domain outright and shows
            // "an error occurred, the items may be out of date" with no way
            // forward, so nothing may leave here unmapped.
            return NSFileProviderError(.cannotSynchronize)
        }
    }
}
