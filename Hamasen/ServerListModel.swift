import AppKit
import FileProvider
import Foundation
import HamasenCore
import Observation
// For move(fromOffsets:toOffset:), whose handling of a downward move is
// easy to get subtly wrong by hand.
import SwiftUI

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
    /// Something the user may want to act on, from here or from the sweep.
    var notice: Notice?

    /// What the system is currently transferring for this domain.
    let transfers = TransferMonitor()
    /// What the mounted servers hold on this Mac, and what keeps it within
    /// bounds.
    let cache = CacheSupervisor()

    private let credentialStore = KeychainCredentialStore()

    /// The two stores in the App Group container, which either both open or
    /// neither does.
    private struct Stores {
        let servers: ServerConfigStore
        let mounted: MountedServersStore
    }

    private var openedStores: Stores?

    /// Opens them once, and reports the one failure they share.
    ///
    /// A computed property would be tidier to read but would open a store on
    /// every access and, worse, set an error message from inside a getter —
    /// state that changes as a side effect of looking at it.
    private func stores() -> Stores? {
        if let openedStores { return openedStores }
        do {
            let opened = Stores(servers: try ServerConfigStore(), mounted: try MountedServersStore())
            openedStores = opened
            return opened
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
        guard let stores = stores() else { return }
        do {
            servers = try stores.servers.loadServers()
            mountedServerIDs = try stores.mounted.loadMountedServerIDs()
        } catch {
            errorMessage = String(localized: "讀取伺服器設定失敗：\(error.localizedDescription)")
            return
        }
        await migrateLegacyDomains()
        await syncDomainRegistration()
        cache.start(
            servers: { [weak self] in self?.mountedServers ?? [] },
            reporting: { [weak self] notice in self?.notice = notice }
        )
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
        guard let stores = stores() else { return false }
        do {
            var updatedServers = servers
            if let existingIndex = updatedServers.firstIndex(where: { $0.id == config.id }) {
                updatedServers[existingIndex] = config
            } else {
                updatedServers.append(config)
            }
            try stores.servers.saveServers(updatedServers)
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
        cache.sweepSoon()
        return true
    }

    func removeServer(_ config: ServerConfig) async {
        guard let stores = stores() else { return }
        await unmount(config)
        do {
            let remainingServers = servers.filter { $0.id != config.id }
            try stores.servers.saveServers(remainingServers)
            try credentialStore.deleteAllCredentials(for: config.id)
            _ = try? PinnedItemsStore().removePins(forServer: config.id)
            servers = remainingServers
        } catch {
            errorMessage = String(localized: "刪除伺服器失敗：\(error.localizedDescription)")
        }
    }

    /// Reorders the list, which is the order it is shown and stored in.
    ///
    /// Written straight through rather than after a confirmation: a drag is
    /// its own confirmation, and a list that sprang back would be worse than
    /// one that saved something the user can simply drag again.
    func moveServers(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard let stores = stores() else { return }
        var reordered = servers
        reordered.move(fromOffsets: source, toOffset: destination)
        do {
            try stores.servers.saveServers(reordered)
        } catch {
            errorMessage = String(localized: "儲存伺服器失敗：\(error.localizedDescription)")
            return
        }
        servers = reordered
        // The Finder folders are listed in this order too, so the change has
        // to reach the extension rather than stopping at the window.
        Task { try? await FinderDomain.signalServerListChanged() }
    }

    // MARK: - Bookmark import

    /// Adds the servers described by Cyberduck or Mountain Duck bookmarks,
    /// then reports what came across and what did not.
    ///
    /// Nothing is mounted and no credential is written: an imported server
    /// still needs its password or key, which those files do not carry.
    func importBookmarks(from files: [CyberduckBookmarkFile]) {
        guard let stores = stores() else { return }
        let summary = CyberduckBookmark.read(files, skippingDuplicatesOf: servers)
        let importedServers = summary.servers.map(\.config)
        if !importedServers.isEmpty {
            let updatedServers = servers + importedServers
            do {
                try stores.servers.saveServers(updatedServers)
            } catch {
                errorMessage = String(localized: "儲存伺服器失敗：\(error.localizedDescription)")
                return
            }
            servers = updatedServers
        }
        notice = Notice(title: String(localized: "匯入書籤"), message: summary.report)
    }

    // MARK: - Backup

    /// Everything about this configuration that can be written down.
    func makeArchive() -> ConfigurationArchive {
        let store = AppSettings.sharedStore
        return ConfigurationArchive(
            exportedAt: Date(),
            servers: servers,
            knownHosts: (try? KnownHostsStore().load()) ?? KnownHosts(),
            settings: ConfigurationArchive.Settings(
                connectTimeoutSeconds: AppSettings.connectTimeoutSeconds(from: store),
                defaultServerPort: AppSettings.defaultServerPort(from: store)
            )
        )
    }

    /// Restores a backup on top of what is already here.
    ///
    /// Merged rather than substituted: importing the wrong file should cost
    /// a few servers to delete, not everything that was configured.
    func restore(_ archive: ConfigurationArchive) {
        guard let stores = stores() else { return }
        let plan = archive.mergePlan(
            against: servers,
            existingHosts: (try? KnownHostsStore().load()) ?? KnownHosts()
        )

        if !plan.servers.isEmpty {
            let updatedServers = servers + plan.servers
            do {
                try stores.servers.saveServers(updatedServers)
            } catch {
                errorMessage = String(localized: "儲存伺服器失敗：\(error.localizedDescription)")
                return
            }
            servers = updatedServers
        }
        try? KnownHostsStore().save(plan.knownHosts)

        let store = AppSettings.sharedStore
        store.set(archive.settings.connectTimeoutSeconds, forKey: AppSettings.Keys.connectTimeoutSeconds)
        store.set(archive.settings.defaultServerPort, forKey: AppSettings.Keys.defaultServerPort)

        notice = Notice(title: String(localized: "匯入設定"), message: Self.report(for: plan))
    }

    private static func report(for plan: ConfigurationArchive.MergePlan) -> String {
        var lines: [String] = []
        if plan.servers.isEmpty {
            lines.append(String(localized: "沒有需要加入的伺服器。"))
        } else {
            let count = plan.servers.count
            lines.append(String(localized: "已加入 \(count) 台伺服器。"))
            lines.append(String(localized: "備份不含密碼與金鑰，請為每台伺服器重新設定登入資訊。"))
        }
        if plan.duplicateCount > 0 {
            lines.append(String(localized: "\(plan.duplicateCount) 台已經在清單中，已略過。"))
        }
        return lines.joined(separator: "\n\n")
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
        guard mountedServerIDs.contains(config.id), let stores = stores() else { return }
        do {
            // The store is the truth the File Provider extension also edits
            // (unmounting from Finder), so take the remaining set from it.
            mountedServerIDs = try stores.mounted.removeMountedServer(config.id)
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
                ? String(localized: "沒有已儲存的密碼，請先輸入密碼再測試")
                : String(localized: "沒有可用的 SSH 金鑰，請先選擇金鑰檔案")
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

    /// The mounted servers, which are the only ones with a local replica to
    /// keep within bounds.
    private var mountedServers: [ServerConfig] {
        servers.filter { mountedServerIDs.contains($0.id) }
    }

    // MARK: - Domain helpers

    private func persistMountedSet() {
        guard let stores = stores() else { return }
        do {
            try stores.mounted.saveMountedServerIDs(mountedServerIDs)
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
        cache.sweepSoon()
    }

}
