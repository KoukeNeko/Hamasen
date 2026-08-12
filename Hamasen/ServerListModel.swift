import AppKit
import FileProvider
import Foundation
import HamasenCore
import Observation

/// View model for the server list: persistence, credentials, and management
/// of the single "Hamasen" File Provider domain. Mounting a server means
/// adding it to the mounted set; it then appears as a top-level folder inside
/// the Hamasen location in Finder.
@MainActor
@Observable
final class ServerListModel {
    var servers: [ServerConfig] = []
    var mountedServerIDs: Set<UUID> = []
    var errorMessage: String?

    private let credentialStore = KeychainCredentialStore()

    private static let mainDomain = NSFileProviderDomain(
        identifier: NSFileProviderDomainIdentifier(rawValue: SharedConstants.mainDomainIdentifier),
        displayName: SharedConstants.mainDomainDisplayName
    )

    private var configStore: ServerConfigStore? {
        do {
            return try ServerConfigStore()
        } catch {
            errorMessage = "無法存取 App Group 容器，請確認簽章設定（App Groups）"
            return nil
        }
    }

    private var mountedStore: MountedServersStore? {
        do {
            return try MountedServersStore()
        } catch {
            errorMessage = "無法存取 App Group 容器，請確認簽章設定（App Groups）"
            return nil
        }
    }

    // MARK: - Loading

    private var hasLoaded = false

    /// Loads once, no matter how many scenes (window, menu bar) appear.
    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await load()
    }

    func load() async {
        hasLoaded = true
        guard let configStore, let mountedStore else { return }
        do {
            servers = try configStore.loadServers()
            mountedServerIDs = try mountedStore.loadMountedServerIDs()
        } catch {
            errorMessage = "讀取伺服器設定失敗：\(error.localizedDescription)"
            return
        }
        await migrateLegacyDomains()
        await syncDomainRegistration()
    }

    /// Earlier versions registered one domain per server (identifier = server
    /// UUID). Convert those registrations into the mounted set and remove
    /// them, so only the single main domain remains.
    private func migrateLegacyDomains() async {
        guard let legacyDomains = try? await NSFileProviderManager.domains()
            .filter({ UUID(uuidString: $0.identifier.rawValue) != nil })
        else { return }

        guard !legacyDomains.isEmpty else { return }
        for domain in legacyDomains {
            if let serverID = UUID(uuidString: domain.identifier.rawValue),
               servers.contains(where: { $0.id == serverID }) {
                mountedServerIDs.insert(serverID)
            }
            try? await NSFileProviderManager.remove(domain)
        }
        persistMountedSet()
    }

    // MARK: - CRUD

    func saveServer(_ config: ServerConfig, password: String) async {
        guard let configStore else { return }
        do {
            var updatedServers = servers
            if let existingIndex = updatedServers.firstIndex(where: { $0.id == config.id }) {
                updatedServers[existingIndex] = config
            } else {
                updatedServers.append(config)
            }
            try configStore.saveServers(updatedServers)
            if !password.isEmpty {
                try credentialStore.savePassword(password, for: config.id)
            }
            servers = updatedServers
        } catch {
            errorMessage = "儲存伺服器失敗：\(error.localizedDescription)"
            return
        }

        // A rename shows up as the folder name in Finder; tell the system to
        // re-check the server list.
        if isMounted(config) {
            await signalServerListChanged()
        }
    }

    func removeServer(_ config: ServerConfig) async {
        guard let configStore else { return }
        await unmount(config)
        do {
            let remainingServers = servers.filter { $0.id != config.id }
            try configStore.saveServers(remainingServers)
            try credentialStore.deletePassword(for: config.id)
            servers = remainingServers
        } catch {
            errorMessage = "刪除伺服器失敗：\(error.localizedDescription)"
        }
    }

    // MARK: - Mounting

    func isMounted(_ config: ServerConfig) -> Bool {
        mountedServerIDs.contains(config.id)
    }

    func mount(_ config: ServerConfig) async {
        mountedServerIDs.insert(config.id)
        persistMountedSet()
        await ensureDomainRegistered()
        await signalServerListChanged()
    }

    func unmount(_ config: ServerConfig) async {
        guard mountedServerIDs.contains(config.id) else { return }
        mountedServerIDs.remove(config.id)
        persistMountedSet()
        if mountedServerIDs.isEmpty {
            try? await NSFileProviderManager.remove(Self.mainDomain)
        } else {
            await signalServerListChanged()
        }
    }

    // MARK: - Finder integration

    /// Opens the mounted Hamasen location in Finder.
    func revealInFinder() async {
        guard let manager = NSFileProviderManager(for: Self.mainDomain) else { return }
        do {
            let url = try await manager.getUserVisibleURL(for: .rootContainer)
            NSWorkspace.shared.open(url)
        } catch {
            errorMessage = "無法開啟 Finder 位置：\(error.localizedDescription)"
        }
    }

    // MARK: - Connection test

    /// Tries a real SFTP connection with the given draft configuration.
    /// Returns nil on success, or a user-facing error message.
    /// An empty passwordOverride falls back to the stored password.
    func testConnection(config: ServerConfig, passwordOverride: String) async -> String? {
        let password: String
        if !passwordOverride.isEmpty {
            password = passwordOverride
        } else {
            do {
                password = try credentialStore.loadPassword(for: config.id)
            } catch {
                return "沒有已儲存的密碼，請先輸入密碼再測試"
            }
        }

        let service = SFTPFileService(
            config: config,
            credentials: .password(password),
            connectTimeoutSeconds: AppSettings.connectTimeoutSeconds()
        )
        defer { Task { try? await service.disconnect() } }
        do {
            try await service.connect()
            _ = try await service.listDirectory(at: RemotePath.root)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Domain helpers

    private func persistMountedSet() {
        guard let mountedStore else { return }
        do {
            try mountedStore.saveMountedServerIDs(mountedServerIDs)
        } catch {
            errorMessage = "儲存掛載狀態失敗：\(error.localizedDescription)"
        }
    }

    /// Registers or removes the main domain so it exists exactly when at
    /// least one server is mounted.
    private func syncDomainRegistration() async {
        if mountedServerIDs.isEmpty {
            try? await NSFileProviderManager.remove(Self.mainDomain)
        } else {
            await ensureDomainRegistered()
        }
    }

    private func ensureDomainRegistered() async {
        do {
            let domains = try await NSFileProviderManager.domains()
            let isRegistered = domains.contains {
                $0.identifier.rawValue == SharedConstants.mainDomainIdentifier
            }
            if !isRegistered {
                try await NSFileProviderManager.add(Self.mainDomain)
            }
        } catch {
            errorMessage = "掛載失敗：\(error.localizedDescription)"
        }
    }

    private func signalServerListChanged() async {
        guard let manager = NSFileProviderManager(for: Self.mainDomain) else { return }
        do {
            try await manager.signalEnumerator(for: .rootContainer)
        } catch {
            // The domain may still be initializing; the next enumeration
            // picks up the change anyway.
        }
    }
}
