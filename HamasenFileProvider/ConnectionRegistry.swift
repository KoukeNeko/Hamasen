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

import FileProvider
import Foundation
import HamasenCore

/// Owns one connection per server for the lifetime of the extension and
/// resolves server configurations from the shared stores.
actor ConnectionRegistry {
    enum RegistryError: Error {
        case serverConfigurationMissing(UUID)
    }

    /// One cached connection attempt. The identity is what lets a caller that
    /// resumes after an `await` tell whether the entry it looked at is still
    /// the one in the cache: another caller may have replaced it meanwhile,
    /// and clearing or overwriting that newer entry would leak its live
    /// session and open a second one for the same server.
    private struct Connection {
        let id = UUID()
        /// The settings the service was made from. A service keeps what it
        /// was given — an S3 endpoint, a host — so one made before the
        /// server was edited would go on using the old settings.
        let config: ServerConfig
        let task: Task<any RemoteFileService, Error>
    }

    /// A service together with the cached session it came from, so a caller
    /// that found the session dead can discard exactly that one and not a
    /// replacement someone else has since made.
    struct Lease {
        let serverID: UUID
        let id: UUID
        let service: any RemoteFileService
    }

    /// The in-flight or completed connection per server. Storing the task
    /// rather than the service closes the window where two callers each build
    /// and connect their own service and the loser is dropped without being
    /// disconnected, leaking its session and credentials.
    private var connections: [UUID: Connection] = [:]

    private let recovery = ServerRecovery()

    /// Returns a connected service for the server, creating one on first use
    /// and replacing one whose session has since died.
    func service(for serverID: UUID) async throws -> any RemoteFileService {
        try await lease(for: serverID).service
    }

    func lease(for serverID: UUID) async throws -> Lease {
        // A session that has gone away — an idle connection the server
        // closed, a sleep, a network change — fails every operation with the
        // same error from then on. Cached, it would keep the server broken
        // until the extension restarts, which is what makes Finder report the
        // same failure however many times the user retries. So the cached
        // entry is checked, and looked up again after each suspension, since
        // what was cached when the wait began may not be what is cached now.
        let config = try Self.config(for: serverID)
        if config.isPaused {
            // A paused server keeps no session open behind the user's back.
            if let cached = connections[serverID], let service = try? await cached.task.value {
                retire(serverID: serverID, id: cached.id, service: service)
            }
            throw RemoteFileServiceError.paused(serverName: config.name)
        }
        while let cached = connections[serverID] {
            if cached.config != config {
                if let stale = try? await cached.task.value {
                    retire(serverID: serverID, id: cached.id, service: stale)
                } else if connections[serverID]?.id == cached.id {
                    connections[serverID] = nil
                }
                continue
            }
            let service: any RemoteFileService
            do {
                service = try await cached.task.value
            } catch {
                // A failed attempt must not be cached, or the server would
                // stay broken until the extension restarts.
                if connections[serverID]?.id == cached.id { connections[serverID] = nil }
                throw error
            }
            if await service.isConnected {
                return Lease(serverID: serverID, id: cached.id, service: service)
            }
            retire(serverID: serverID, id: cached.id, service: service)
        }

        let connection = Connection(config: config, task: Task { () throws -> any RemoteFileService in
            let credentials = try KeychainCredentialStore().loadCredentials(for: config)
            let service = try RemoteFileServiceFactory.makeService(for: config, credentials: credentials)
            try await service.connect()
            return service
        })
        connections[serverID] = connection

        do {
            let service = try await connection.task.value
            return Lease(serverID: serverID, id: connection.id, service: service)
        } catch {
            if connections[serverID]?.id == connection.id { connections[serverID] = nil }
            throw error
        }
    }

    /// Drops a session an operation found dead, so the next `lease` connects
    /// afresh. A no-op when the cache has already moved on to another session.
    func discard(_ lease: Lease) {
        retire(serverID: lease.serverID, id: lease.id, service: lease.service)
    }

    private func retire(serverID: UUID, id: UUID, service: any RemoteFileService) {
        // Whoever removes the entry tears the session down, so it happens once.
        guard connections[serverID]?.id == id else { return }
        connections[serverID] = nil
        // Not awaited: the session is already gone, so its teardown has
        // nothing left to do for this caller, and the registry has to stay
        // answerable to every other server while it happens.
        Task { try? await service.disconnect() }
    }

    func shutdownAll() async {
        await recovery.stop()
        let pending = connections.values
        connections.removeAll()
        for connection in pending {
            guard let service = try? await connection.task.value else { continue }
            try? await service.disconnect()
        }
    }

    /// Records that an operation on the server failed to reach it. The system
    /// answers `.serverUnreachable` by waiting until it is told the error is
    /// resolved, so something has to notice when the server is back.
    func reportUnreachable(_ serverID: UUID) async {
        await recovery.reportUnreachable(serverID) { [self] in
            try await probe(serverID)
        }
    }

    /// Records that an operation on the server succeeded.
    func reportReachable(_ serverID: UUID) async {
        await recovery.reportReachable(serverID)
    }

    /// Throws only while the server still cannot be reached. Any other
    /// failure — refused credentials, a missing root — means it answered,
    /// and the operations that follow report their own errors.
    private func probe(_ serverID: UUID) async throws {
        do {
            let leased = try await lease(for: serverID)
            do {
                try await leased.service.checkReachable()
            } catch {
                if FileProviderErrorMapper.isConnectionFailure(error) { discard(leased) }
                throw error
            }
        } catch {
            if FileProviderErrorMapper.isConnectionFailure(error) || error is CancellationError { throw error }
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

/// Maps service-layer errors to errors the system accepts.
///
/// Which code an error gets decides how much of the domain it stops. The
/// header has `.serverUnreachable`, `.notAuthenticated` and
/// `.cannotSynchronize` make the system back off "until the next time it is
/// signalled", for everything in the domain, so they are reserved for
/// states that really are domain-wide. Every server shares this one domain,
/// so one server out of reach or refusing its password pauses all of them:
/// only a write takes that price, since the system drops a transient
/// failure after a few retries and a change would never reach the server.
/// A read is retried for its item alone. Any other error is too.
enum FileProviderErrorMapper {
    /// What the system was doing, which decides how a refusal reads: the
    /// header has no code for "permission denied", so the Cocoa ones stand in.
    enum Operation {
        case read
        case write
    }

    static func map(_ error: Error, during operation: Operation = .read) -> Error {
        switch error {
        case is CancellationError:
            return CocoaError(.userCancelled)
        case RemoteFileServiceError.connectionFailed, RemoteFileServiceError.notConnected:
            // A read is asked for again when it is needed. Paused instead, it
            // would hold up every other server for as long as this one stays
            // out of reach — a NAS on another network can be, for days.
            return operation == .read ? retriedForTheItem(error) : NSFileProviderError(.serverUnreachable)
        case RemoteFileServiceError.itemNotFound,
             ConnectionRegistry.RegistryError.serverConfigurationMissing:
            return NSFileProviderError(.noSuchItem)
        case RemoteFileServiceError.alreadyExists:
            return NSFileProviderError(.filenameCollision)
        case RemoteFileServiceError.paused:
            // Pausing one server must leave every other one working.
            return retriedForTheItem(error)
        case RemoteFileServiceError.permissionDenied:
            return CocoaError(operation == .read ? .fileReadNoPermission : .fileWriteNoPermission)
        case _ where isAuthenticationFailure(error):
            // As above. The app asks for the credentials either way.
            return operation == .read ? retriedForTheItem(error) : NSFileProviderError(.notAuthenticated)
        default:
            let domain = (error as NSError).domain
            if domain == NSCocoaErrorDomain || domain == NSFileProviderErrorDomain {
                return error
            }
            // The system rejects any other error domain outright. This code
            // is the one it treats as transient, retried for the item alone.
            return CocoaError(.xpcConnectionReplyInvalid, userInfo: [NSUnderlyingErrorKey: error])
        }
    }

    /// The system's transient error, carrying the reason so Finder can show
    /// it. The only domain it accepts besides its own is Cocoa's.
    private static func retriedForTheItem(_ error: Error) -> Error {
        CocoaError(.xpcConnectionReplyInvalid, userInfo: [
            NSLocalizedDescriptionKey: error.localizedDescription, NSUnderlyingErrorKey: error,
        ])
    }

    /// The stored credential or identity cannot be used, and retrying will
    /// not help until the person acts in the app. A changed host key counts:
    /// only clearing it there lets the connection through.
    static func isAuthenticationFailure(_ error: Error) -> Bool {
        switch error {
        case RemoteFileServiceError.authenticationFailed,
             is KeychainCredentialStore.KeychainError,
             RemoteFileServiceError.unsupportedCredentials,
             RemoteFileServiceError.privateKeyPassphraseRequired,
             RemoteFileServiceError.privateKeyUnreadable,
             RemoteFileServiceError.hostKeyChanged:
            return true
        default:
            return false
        }
    }

    /// Whether the connection itself failed, as opposed to the server
    /// answering with a refusal.
    static func isConnectionFailure(_ error: Error) -> Bool {
        switch error {
        case RemoteFileServiceError.connectionFailed, RemoteFileServiceError.notConnected:
            return true
        default:
            return false
        }
    }
}
