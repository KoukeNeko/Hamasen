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
import HamasenCore
import Observation

/// Keeps what the mounted servers hold on this Mac within what each of them
/// allows, and keeps the figures for it current.
///
/// Separate from the list of servers because it runs on its own schedule and
/// outlives any one change to that list: content becomes evictable with
/// nothing else happening — a file is closed, an upload finishes — and the
/// figures go stale the same way.
@MainActor
@Observable
final class CacheSupervisor {
    /// How often a sweep runs on its own, between the passes that changes to
    /// the server list trigger.
    private static let sweepInterval = Duration.seconds(300)

    /// How often a view showing the figures measures them again.
    static let refreshInterval = Duration.seconds(5)

    /// What each server is holding on this Mac.
    private(set) var usage: [UUID: CacheUsage] = [:]

    private let evictor = CacheEvictor()
    private var schedule: Task<Void, Never>?
    /// Once per run rather than once ever: the condition is fixable, and
    /// someone who fixes it should hear about it again if it comes back.
    private var hasReportedPinnedOverage = false

    /// Read again on every pass rather than captured once, because the
    /// mounted set changes while the schedule runs.
    private var mountedServers: @MainActor () -> [ServerConfig] = { [] }
    private var report: @MainActor (Notice) -> Void = { _ in }

    /// Begins sweeping, and says where to find the servers and where to send
    /// what a sweep cannot resolve on its own.
    func start(
        servers: @escaping @MainActor () -> [ServerConfig],
        reporting: @escaping @MainActor (Notice) -> Void
    ) {
        mountedServers = servers
        report = reporting
        guard schedule == nil else { return }
        schedule = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sweep()
                try? await Task.sleep(for: Self.sweepInterval)
            }
        }
    }

    /// Frees what is over each server's allowance, without making the caller
    /// wait for a pass that can cover thousands of items.
    func sweepSoon() {
        Task { await sweep() }
    }

    func sweep() async {
        let servers = mountedServers()
        guard !servers.isEmpty else { return }
        let outcome = await evictor.evictContent(for: servers)
        if outcome.needsRemount {
            reportContentThatOnlyARemountCanFree()
        }
        reportServersHeldOverByPins(outcome.heldOverByPins, among: servers)
        usage = outcome.usage
    }

    /// Measures without enforcing anything, for a view that would otherwise
    /// show what the last sweep saw.
    func refreshUsage() async {
        let servers = mountedServers()
        guard !servers.isEmpty else {
            usage = [:]
            return
        }
        usage = await evictor.measureUsage(for: servers)
    }

    // MARK: - What a sweep cannot fix

    /// Warns that an allowance cannot be met, because the content over it is
    /// content the user asked to keep.
    ///
    /// A limit that silently does not hold is worse than no limit: the disk
    /// keeps filling and the setting says otherwise.
    private func reportServersHeldOverByPins(
        _ overages: [UUID: PinnedOverage],
        among servers: [ServerConfig]
    ) {
        guard !overages.isEmpty, !hasReportedPinnedOverage else { return }
        let affected = servers
            .filter { overages[$0.id] != nil }
            .map(\.name)
            .sorted()
        guard let first = affected.first, let overage = overages.first?.value else { return }
        hasReportedPinnedOverage = true

        let pinned = ByteCountFormatter.string(fromByteCount: overage.pinnedBytes, countStyle: .file)
        let allowance = ByteCountFormatter.string(fromByteCount: overage.allowanceBytes, countStyle: .file)
        report(
            Notice(
                title: String(localized: "超出本機空間上限"),
                message: affected.count == 1
                    ? String(localized: "「\(first)」保留在本機的檔案已達 \(pinned)，超過上限 \(allowance)。取消保留部分檔案，或把上限調高。")
                    : String(localized: "\(affected.count) 台伺服器保留的檔案超過各自的上限。取消保留部分檔案，或把上限調高。")
            )
        )
    }

    /// Content stored before Hamasen declared it evictable cannot be freed in
    /// place — the permission travels with the item, and those items were
    /// written without it. Remounting rebuilds the local copy, which is the
    /// only way out, and it is worth saying once rather than leaving the
    /// setting looking broken.
    private func reportContentThatOnlyARemountCanFree() {
        let store = AppSettings.sharedStore
        guard !store.bool(forKey: AppSettings.Keys.hasShownRemountForOnlineOnly) else { return }
        store.set(true, forKey: AppSettings.Keys.hasShownRemountForOnlineOnly)
        report(
            Notice(
                title: String(localized: "純線上模式"),
                message: String(
                    localized: "部分既有內容是在「純線上」推出前下載的，無法直接釋放。將這台伺服器卸載再重新掛載即可清除，之後下載的內容都會自動釋放。"
                )
            )
        )
    }
}
