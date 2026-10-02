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
    private static let log = HamasenLog(category: "model")

    var servers: [ServerConfig] = []
    var mountedServerIDs: Set<UUID> = []
    var errorMessage: String?
    /// Something the user may want to act on, from here or from the sweep.
    var notice: Notice?
    /// Whether the person has switched the Finder location on in System
    /// Settings; nil while it is not in Finder or not yet known.
    private(set) var isDomainEnabled: Bool?

    /// What the extension is transferring, what finished, the conflicts it
    /// kept, and how each server answered it.
    let activity = ActivityMonitor()
    /// What the mounted servers hold on this Mac, and what keeps it within
    /// bounds.
    let cache = CacheSupervisor()
    let remoteChanges = RemoteChangeWatcher()
    let index = WorkingSetRefresher()
    let updates = UpdateChecker()

    /// How each server answered the app's own checks, beside what the
    /// extension reports; whichever changed last is the one shown.
    private var observedHealth: [UUID: ServerHealth] = [:]
    /// The status each connection was last announced in, so a notification
    /// goes out when a connection gets into trouble and not on every look.
    private var announcedStatuses: [UUID: ConnectionStatus]?

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
        // Everything that watches and reports starts before the domain is
        // registered, not after: registering waits for fileproviderd, which
        // can spend minutes starting a large domain after the extension was
        // updated, and none of this needs the registration to have finished.
        cache.start(
            servers: { [weak self] in self?.mountedServers ?? [] },
            reporting: { [weak self] notice in self?.notice = notice }
        )
        activity.start(
            onNewConflicts: { [weak self] conflicts in self?.announce(conflicts) },
            onChange: { [weak self] in self?.announceStatusChanges() }
        )
        remoteChanges.start(
            servers: { [weak self] in self?.mountedServers.filter { !$0.isPaused } ?? [] },
            observing: { [weak self] health, serverID in self?.observe(health, for: serverID) }
        )
        index.start()
        updates.startAutomaticChecks()
        observeDomainChanges()
        announceStatusChanges()

        await migrateLegacyDomains()
        await refreshDomainState()
        await syncDomainRegistration()
        await refreshDomainState()
        _ = try? await FinderDomain.releaseDomainWidePauses()
    }

    /// Earlier versions registered one domain per server (identifier = server
    /// UUID). Convert those registrations into the mounted set and remove
    /// them, so only the single main domain remains.
    private func migrateLegacyDomains() async {
        guard let legacyDomains = try? await NSFileProviderManager.domains()
            .filter({ UUID(uuidString: $0.identifier.rawValue) != nil })
        else { return }

        guard !legacyDomains.isEmpty else { return }
        var legacyServerIDs: Set<UUID> = []
        for domain in legacyDomains {
            if let serverID = UUID(uuidString: domain.identifier.rawValue),
               servers.contains(where: { $0.id == serverID }) {
                legacyServerIDs.insert(serverID)
            }
            try? await NSFileProviderManager.remove(domain)
        }
        persistMountedServers(adding: legacyServerIDs)
    }

    // MARK: - CRUD

    @discardableResult
    func saveServer(_ config: ServerConfig, credentials: CredentialUpdate) async -> Bool {
        guard let stores = stores() else { return false }
        let previous = servers.first { $0.id == config.id }
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

        // A rename shows up as the folder name in Finder, and new credentials
        // may clear a sign-in failure that paused the whole domain; tell the
        // system both.
        if isMounted(config) {
            // The domain may still be initializing; the next enumeration
            // picks the rename up anyway.
            _ = try? await FinderDomain.signalAuthenticationResolved()
        }
        if previous?.indexesInBackground != config.indexesInBackground {
            index.settingsChanged()
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
            observedHealth[config.id] = nil
            activity.forget(serverID: config.id)
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
        Task {
            _ = try? await FinderDomain.signalWorkingSet()
        }
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

    /// The same configuration plus every secret behind it, for a backup the
    /// user has chosen to protect with a passphrase.
    func makeProtectedArchive() -> ProtectedConfigurationArchive {
        var credentials: [ProtectedConfigurationArchive.Credential] = []
        for server in servers {
            for kind in KeychainCredentialStore.CredentialKind.allCases {
                guard let secret = try? credentialStore.load(kind: kind, for: server.id) else {
                    continue
                }
                credentials.append(
                    .init(serverID: server.id, kind: kind.rawValue, secret: secret)
                )
            }
        }
        return ProtectedConfigurationArchive(
            configuration: makeArchive(),
            credentials: credentials
        )
    }

    /// Restores a protected backup, secrets included.
    func restore(_ archive: ProtectedConfigurationArchive) {
        let plan = makePlan(for: archive.configuration)
        guard apply(plan, settings: archive.configuration.settings) else { return }

        for credential in archive.credentials(remappedBy: plan.identifierRemapping) {
            guard let kind = KeychainCredentialStore.CredentialKind(rawValue: credential.kind) else {
                continue
            }
            try? credentialStore.save(credential.secret, kind: kind, for: credential.serverID)
        }
        notice = Notice(title: String(localized: "匯入設定"), message: Self.report(for: plan, includedSecrets: true))
    }

    /// Restores a backup on top of what is already here.
    ///
    /// Merged rather than substituted: importing the wrong file should cost
    /// a few servers to delete, not everything that was configured.
    func restore(_ archive: ConfigurationArchive) {
        let plan = makePlan(for: archive)
        guard apply(plan, settings: archive.settings) else { return }
        notice = Notice(title: String(localized: "匯入設定"), message: Self.report(for: plan, includedSecrets: false))
    }

    private func makePlan(for archive: ConfigurationArchive) -> ConfigurationArchive.MergePlan {
        archive.mergePlan(
            against: servers,
            existingHosts: (try? KnownHostsStore().load()) ?? KnownHosts()
        )
    }

    /// Writes one plan, once.
    ///
    /// The plan is made by the caller and passed in because it names the
    /// identifiers the restored servers will have: making it twice would
    /// produce two sets of them, and anything keyed by the first — the
    /// credentials — would be filed against servers that do not exist.
    private func apply(
        _ plan: ConfigurationArchive.MergePlan,
        settings: ConfigurationArchive.Settings
    ) -> Bool {
        guard let stores = stores() else { return false }

        if !plan.servers.isEmpty {
            let updatedServers = servers + plan.servers
            do {
                try stores.servers.saveServers(updatedServers)
            } catch {
                errorMessage = String(localized: "儲存伺服器失敗：\(error.localizedDescription)")
                return false
            }
            servers = updatedServers
        }
        try? KnownHostsStore().save(plan.knownHosts)

        let store = AppSettings.sharedStore
        store.set(settings.connectTimeoutSeconds, forKey: AppSettings.Keys.connectTimeoutSeconds)
        store.set(settings.defaultServerPort, forKey: AppSettings.Keys.defaultServerPort)
        return true
    }

    private static func report(
        for plan: ConfigurationArchive.MergePlan,
        includedSecrets: Bool
    ) -> String {
        var lines: [String] = []
        if plan.servers.isEmpty {
            lines.append(String(localized: "沒有需要加入的伺服器。"))
        } else {
            let count = plan.servers.count
            lines.append(String(localized: "已加入 \(count) 台伺服器。"))
            if !includedSecrets {
                lines.append(String(localized: "備份不含密碼與金鑰，請為每台伺服器重新設定登入資訊。"))
            }
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
        persistMountedServers(adding: [config.id])
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
        // Its directories would be reported as new when it comes back. A miss
        // is reclaimed by the poll's next `keepOnly` or by pruning.
        try? RemoteDirectorySnapshotStore().forget(serverID: config.id)
        try? RemoteDirectorySnapshotStore.walkRecord().forget(serverID: config.id)
        await syncDomainRegistration()
    }

    // MARK: - Finder integration

    /// Opens the mounted Hamasen location in Finder, or one server's folder
    /// inside it.
    func revealInFinder(_ server: ServerConfig? = nil) async {
        guard let manager = NSFileProviderManager(for: FinderDomain.domain) else { return }
        let identifier = server.map { ItemIdentifierMapper.identifier(for: .serverRoot($0.id)) } ?? .rootContainer
        do {
            let url = try await manager.getUserVisibleURL(for: identifier)
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

    /// Shows one item in Finder, selected — a conflict copy, for instance.
    func revealItem(serverID: UUID, path: String) async {
        guard let manager = try? FinderDomain.manager() else { return }
        let identifier = ItemIdentifierMapper.identifier(
            for: ItemIdentifierMapper.directoryEntity(serverID: serverID, path: path))
        do {
            let url = try await manager.getUserVisibleURL(for: identifier)
            let hasScopedAccess = url.startAccessingSecurityScopedResource()
            defer { if hasScopedAccess { url.stopAccessingSecurityScopedResource() } }
            NSWorkspace.shared.activateFileViewerSelecting([url])
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

    /// Whether a cloud drive connection has a sign-in stored.
    func hasStoredToken(for serverID: UUID) -> Bool {
        hasStoredCredential(kind: .oauthToken, for: serverID)
    }

    /// The stored password, for asking an SMB server which shares it has
    /// before an edit is saved.
    func storedPassword(for serverID: UUID) -> String? {
        try? credentialStore.load(kind: .password, for: serverID)
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
            switch config.authenticationMethod {
            case .password: return String(localized: "沒有已儲存的密碼，請先輸入密碼再測試")
            case .privateKey: return String(localized: "沒有可用的 SSH 金鑰，請先選擇金鑰檔案")
            case .oauth: return String(localized: "尚未登入，請先在瀏覽器登入")
            }
        }

        let service: any RemoteFileService
        do {
            service = try RemoteFileServiceFactory.makeService(for: config, credentials: credentials)
        } catch {
            return error.localizedDescription
        }
        defer { Task { try? await service.disconnect() } }
        // Every protocol has its own timeout, and a host that accepts the
        // connection and then says nothing can still outlast them; the test
        // as a whole gives up after the same time, so the form never spins
        // for good.
        let limit = AppSettings.connectTimeoutSeconds() + 5
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await service.connect()
                    _ = try await service.listDirectory(at: RemotePath.root)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(limit))
                    throw RemoteFileServiceError.connectionFailed(underlying: String(localized: "連線逾時"))
                }
                defer { group.cancelAll() }
                try await group.next()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Adding

    /// Adds a connection only once it has been shown to work, and mounts it.
    ///
    /// Returns why it could not be added. Nothing is saved in that case, so a
    /// connection that never worked is not left in the list for the person
    /// to find and delete; the form keeps what they typed for another try.
    func addConnection(_ config: ServerConfig, credentials: CredentialUpdate) async -> String? {
        if let failure = await testConnection(config: config, credentials: credentials) {
            return failure
        }
        guard await saveServer(config, credentials: credentials) else {
            return errorMessage ?? String(localized: "儲存連線失敗")
        }
        await mount(config)
        return nil
    }

    /// Signs in to a cloud drive in the browser and says whose account it
    /// was.
    func signIn(to provider: OAuthProvider) async throws -> (token: OAuthToken, email: String) {
        let token = try await OAuthSignIn.signIn(provider: provider)
        let email = (try? await CloudAccount.email(signedInWith: token)) ?? ""
        return (token, email)
    }

    // MARK: - Pausing

    /// Pauses or resumes a connection. A paused one stays in Finder with
    /// what is already on this Mac; nothing is sent or fetched until it is
    /// resumed.
    func setPaused(_ isPaused: Bool, for config: ServerConfig) async {
        guard var updated = servers.first(where: { $0.id == config.id }), updated.isPaused != isPaused else {
            return
        }
        updated.isPaused = isPaused
        guard await saveServer(updated, credentials: CredentialUpdate()) else { return }
        // The folder's badge changes, and on resume whatever waited while
        // paused is asked for again.
        _ = try? await FinderDomain.signalWorkingSet()
        if !isPaused, let manager = try? FinderDomain.manager() {
            try? await manager.reimportItems(below: ItemIdentifierMapper.identifier(for: .serverRoot(config.id)))
        }
        announceStatusChanges()
    }

    // MARK: - Status

    /// What a connection is doing, from the extension's reports and the
    /// app's own checks.
    func status(for config: ServerConfig) -> ConnectionStatus {
        guard isMounted(config) else { return .notMounted }
        if config.isPaused { return .paused }
        switch health(for: config.id)?.state {
        case .unreachable?: return .unreachable(health(for: config.id)?.message)
        case .signInRequired?: return .signInRequired(health(for: config.id)?.message)
        case .reachable?, nil: break
        }
        return activity.transfers(for: config.id).isEmpty ? .connected : .syncing
    }

    var overallStatus: OverallStatus {
        OverallStatus.combining(servers.map(status(for:)))
    }

    private func health(for serverID: UUID) -> ServerHealth? {
        switch (activity.health(for: serverID), observedHealth[serverID]) {
        case let (reported?, observed?): return reported.since >= observed.since ? reported : observed
        case let (reported, observed): return reported ?? observed
        }
    }

    func observe(_ health: ServerHealth, for serverID: UUID) {
        if let current = observedHealth[serverID], current.state == health.state, current.message == health.message {
            return
        }
        observedHealth[serverID] = health
        announceStatusChanges()
    }

    /// Notifies when a connection gets into trouble. Called whenever what
    /// the status is made of changes; the first call only records where
    /// things stand, since trouble that was there at launch is not news.
    func announceStatusChanges() {
        var current: [UUID: ConnectionStatus] = [:]
        for server in servers { current[server.id] = status(for: server) }
        defer { announcedStatuses = current }
        guard let previous = announcedStatuses else { return }
        for server in servers {
            guard let status = current[server.id], status != previous[server.id] else { continue }
            switch status {
            case .unreachable(let message) where !(previous[server.id]?.needsAttention ?? false):
                AppNotifier.connectionLost(server, message: message)
            case .signInRequired:
                AppNotifier.signInRequired(server)
            default:
                break
            }
        }
    }

    private func announce(_ conflicts: [ConflictRecord]) {
        for conflict in conflicts {
            let name = servers.first { $0.id == conflict.serverID }?.name ?? ""
            AppNotifier.conflict(conflict, serverName: name)
        }
        announceStatusChanges()
    }

    // MARK: - System Settings

    /// Reads whether the Finder location is switched on, which macOS asks
    /// the person to do once in System Settings.
    func refreshDomainState() async {
        do {
            let domains = try await NSFileProviderManager.domains()
            // Hidden means nothing is mounted, and there is nothing to
            // switch on until something is.
            isDomainEnabled = domains.first {
                $0.identifier == FinderDomain.domain.identifier && !$0.isHidden
            }?.userEnabled
        } catch {
            // What was last known stays: a failed lookup says nothing about
            // whether the switch moved.
            Self.log.error("Could not read the Finder location's state: \(error.localizedDescription)")
        }
    }

    private var domainObserver: NSObjectProtocol?

    private func observeDomainChanges() {
        guard domainObserver == nil else { return }
        domainObserver = NotificationCenter.default.addObserver(
            forName: .fileProviderDomainDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshDomainState() }
        }
    }

    /// Opens Login Items & Extensions, where File Providers are switched on.
    func openFileProviderSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The mounted servers, which are the only ones with a local replica to
    /// keep within bounds.
    private var mountedServers: [ServerConfig] {
        servers.filter { mountedServerIDs.contains($0.id) }
    }

    // MARK: - Domain helpers

    /// Adds to the mounted set by delta and takes the result from the store.
    ///
    /// The extension removes servers from the same file (unmounting from
    /// Finder), so writing back the set this model holds could undo that.
    private func persistMountedServers(adding serverIDs: Set<UUID>) {
        guard let stores = stores() else { return }
        do {
            mountedServerIDs = try stores.mounted.addMountedServers(serverIDs)
        } catch {
            errorMessage = String(localized: "儲存掛載狀態失敗：\(error.localizedDescription)")
        }
    }

    /// Empties the Finder location and builds it again.
    func resetFinderLocation() async {
        do {
            try await FinderDomain.reset(hasMountedServers: !mountedServerIDs.isEmpty)
        } catch {
            errorMessage = String(localized: "重設 Finder 位置失敗：\(error.localizedDescription)")
        }
        await refreshDomainState()
        cache.sweepSoon()
    }

    /// Shows the main domain in Finder exactly when at least one server is
    /// mounted.
    private func syncDomainRegistration() async {
        var preservedLocation: URL?
        do {
            preservedLocation = try await FinderDomain.synchronize(
                hasMountedServers: !mountedServerIDs.isEmpty
            )
        } catch {
            errorMessage = String(localized: "更新 Finder 位置失敗：\(error.localizedDescription)")
        }
        // Replacing an outdated domain keeps content that never made it to
        // the server wherever the system chooses; showing it is the only
        // way the user learns it is there.
        if let preservedLocation {
            NSWorkspace.shared.activateFileViewerSelecting([preservedLocation])
        }
        cache.sweepSoon()
    }

}
