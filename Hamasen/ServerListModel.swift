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
    private let evictor = OnlineOnlyEvictor()
    private var evictionTimer: Task<Void, Never>?

    private var configStore: ServerConfigStore? {
        do {
            return try ServerConfigStore()
        } catch {
            errorMessage = String(localized: "無法存取 App Group 容器，請確認簽章設定（App Groups）")
            return nil
        }
    }

    private var mountedStore: MountedServersStore? {
        do {
            return try MountedServersStore()
        } catch {
            errorMessage = String(localized: "無法存取 App Group 容器，請確認簽章設定（App Groups）")
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
            errorMessage = String(localized: "讀取伺服器設定失敗：\(error.localizedDescription)")
            return
        }
        await migrateLegacyDomains()
        await syncDomainRegistration()
        startEvictionSchedule()
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

    @discardableResult
    func saveServer(_ config: ServerConfig, credentials: CredentialUpdate) async -> Bool {
        guard let configStore else { return false }
        do {
            var updatedServers = servers
            if let existingIndex = updatedServers.firstIndex(where: { $0.id == config.id }) {
                updatedServers[existingIndex] = config
            } else {
                updatedServers.append(config)
            }
            try configStore.saveServers(updatedServers)
            try credentials.apply(to: config.id, using: credentialStore)
            servers = updatedServers
        } catch {
            errorMessage = String(localized: "儲存伺服器失敗：\(error.localizedDescription)")
            return false
        }

        // A rename shows up as the folder name in Finder; tell the system to
        // re-check the server list.
        if isMounted(config) {
            // The domain may still be initializing; the next enumeration
            // picks the rename up anyway.
            try? await FinderDomain.signalServerListChanged()
        }
        evictOnlineOnlyContent()
        return true
    }

    func removeServer(_ config: ServerConfig) async {
        guard let configStore else { return }
        await unmount(config)
        do {
            let remainingServers = servers.filter { $0.id != config.id }
            try configStore.saveServers(remainingServers)
            try credentialStore.deleteAllCredentials(for: config.id)
            servers = remainingServers
        } catch {
            errorMessage = String(localized: "刪除伺服器失敗：\(error.localizedDescription)")
        }
    }

    // MARK: - Mounting

    func isMounted(_ config: ServerConfig) -> Bool {
        mountedServerIDs.contains(config.id)
    }

    func mount(_ config: ServerConfig) async {
        mountedServerIDs.insert(config.id)
        persistMountedSet()
        await syncDomainRegistration()
    }

    func unmount(_ config: ServerConfig) async {
        guard mountedServerIDs.contains(config.id), let mountedStore else { return }
        do {
            // The store is the truth the File Provider extension also edits
            // (unmounting from Finder), so take the remaining set from it.
            mountedServerIDs = try mountedStore.removeMountedServer(config.id)
        } catch {
            errorMessage = String(localized: "儲存掛載狀態失敗：\(error.localizedDescription)")
            return
        }
        await syncDomainRegistration()
    }

    // MARK: - Finder integration

    /// Opens the mounted Hamasen location in Finder.
    func revealInFinder() async {
        guard let manager = NSFileProviderManager(for: FinderDomain.domain) else { return }
        do {
            let url = try await manager.getUserVisibleURL(for: .rootContainer)
            // getUserVisibleURL vends a security-scoped URL: a sandboxed app
            // has no standing access to ~/Library/CloudStorage and must claim
            // it before handing the location to Finder.
            let hasScopedAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasScopedAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            NSWorkspace.shared.open(url)
        } catch {
            errorMessage = String(localized: "無法開啟 Finder 位置：\(error.localizedDescription)")
        }
    }

    // MARK: - Connection test

    /// Whether a private key is already stored for this server, so the UI can
    /// tell "keep the existing key" apart from "no key yet".
    func hasStoredPrivateKey(for serverID: UUID) -> Bool {
        hasStoredCredential(kind: .privateKey, for: serverID)
    }

    /// Whether a password is already stored, so an edit form can leave the
    /// field blank without implying the server has no credential.
    func hasStoredPassword(for serverID: UUID) -> Bool {
        hasStoredCredential(kind: .password, for: serverID)
    }

    /// Only a definite "no such item" counts as absent. Any other Keychain
    /// failure — locked, interaction not allowed, access-group mismatch — is
    /// reported as present, because treating it as absent would disable the
    /// form's Save button with nothing on screen explaining why.
    private func hasStoredCredential(
        kind: KeychainCredentialStore.CredentialKind,
        for serverID: UUID
    ) -> Bool {
        do {
            _ = try credentialStore.load(kind: kind, for: serverID)
            return true
        } catch KeychainCredentialStore.KeychainError.itemNotFound {
            return false
        } catch {
            return true
        }
    }

    /// Tries a real connection with the given draft configuration, using
    /// whichever protocol it names.
    /// Returns nil on success, or a user-facing error message. Credentials
    /// the user has not re-entered fall back to what is stored.
    func testConnection(config: ServerConfig, credentials draft: CredentialUpdate) async -> String? {
        let credentials: ServerCredentials
        do {
            credentials = try draft.resolve(for: config, using: credentialStore)
        } catch {
            return config.authenticationMethod == .password
                ? "沒有已儲存的密碼，請先輸入密碼再測試"
                : "沒有可用的 SSH 金鑰，請先選擇金鑰檔案"
        }

        let service = RemoteFileServiceFactory.makeService(for: config, credentials: credentials)
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
            errorMessage = String(localized: "儲存掛載狀態失敗：\(error.localizedDescription)")
        }
    }

    /// Registers or removes the main domain so it exists exactly when at
    /// least one server is mounted.
    private func syncDomainRegistration() async {
        var preservedLocation: URL?
        do {
            preservedLocation = try await FinderDomain.synchronize(
                hasMountedServers: !mountedServerIDs.isEmpty
            )
        } catch {
            errorMessage = String(localized: "更新 Finder 位置失敗：\(error.localizedDescription)")
        }
        // Content that never made it to the server survives the unmount;
        // showing it is the only way the user learns it is there.
        if let preservedLocation {
            NSWorkspace.shared.activateFileViewerSelecting([preservedLocation])
        }
        evictOnlineOnlyContent()
    }

    // MARK: - Online-only storage

    /// Servers whose content the user asked not to keep on this Mac. Only
    /// mounted ones: an unmounted server has no local replica to free.
    private var onlineOnlyServerIDs: Set<UUID> {
        Set(
            servers
                .filter { mountedServerIDs.contains($0.id) && $0.storageMode == .onlineOnly }
                .map(\.id)
        )
    }

    /// Frees what online-only servers are holding, without making the caller
    /// wait for a sweep that can cover thousands of items.
    private func evictOnlineOnlyContent() {
        let serverIDs = onlineOnlyServerIDs
        guard !serverIDs.isEmpty else { return }
        Task { [evictor] in await evictor.evictContent(of: serverIDs) }
    }

    /// A pass runs on every change, but content also becomes evictable
    /// without anything changing here — a file is closed, an upload
    /// finishes — so the sweep repeats while the app is running.
    private func startEvictionSchedule() {
        guard evictionTimer == nil else { return }
        evictionTimer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.evictOnlineOnlyContentNow()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    private func evictOnlineOnlyContentNow() async {
        let serverIDs = onlineOnlyServerIDs
        guard !serverIDs.isEmpty else { return }
        await evictor.evictContent(of: serverIDs)
    }
}
