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
import Network

/// Tells the system when a server it gave up on is reachable again.
///
/// The header has `.serverUnreachable` make the system back off until it is
/// signalled, and nothing else signals it: without this, one dropped
/// connection would leave every transfer in the domain waiting for good.
/// A probe per server retries with a growing delay, and the network coming
/// back skips the wait. If the extension is torn down while a probe is
/// pending, the system's own retry of the item starts the cycle again.
actor ServerRecovery {
    private static let initialDelay = Duration.seconds(5)
    private static let maximumDelay = Duration.seconds(120)
    private static let log = HamasenLog(category: "recovery")

    private struct Pending {
        let generation: UUID
        let probe: @Sendable () async throws -> Void
        let task: Task<Void, Never>
    }

    /// At most one probe per server.
    private var pending: [UUID: Pending] = [:]
    private var monitor: NWPathMonitor?
    /// Nil until the monitor's first report, which describes the network as
    /// it already is and not a change worth acting on.
    private var networkWasAvailable: Bool?

    /// Starts probing the server unless a probe is already running. `probe`
    /// throws while the server is still unreachable.
    func reportUnreachable(_ serverID: UUID, probe: @escaping @Sendable () async throws -> Void) {
        guard pending[serverID] == nil else { return }
        Self.log.notice("Server \(serverID) unreachable; probing until it answers")
        startMonitoringNetwork()
        schedule(serverID, probe: probe, firstDelay: Self.initialDelay)
    }

    /// An operation succeeded, so the server is reachable whatever the probe
    /// has seen so far.
    func reportReachable(_ serverID: UUID) async {
        guard let running = pending.removeValue(forKey: serverID) else { return }
        running.task.cancel()
        await resolve()
    }

    func stop() {
        pending.values.forEach { $0.task.cancel() }
        pending.removeAll()
        monitor?.cancel()
        monitor = nil
    }

    private func schedule(
        _ serverID: UUID, probe: @escaping @Sendable () async throws -> Void, firstDelay: Duration
    ) {
        let generation = UUID()
        let task = Task { [weak self] in
            var delay = firstDelay
            while !Task.isCancelled {
                if delay > .zero {
                    try? await Task.sleep(for: delay)
                }
                if Task.isCancelled { return }
                do {
                    try await probe()
                    await self?.recovered(serverID, generation: generation)
                    return
                } catch {
                    delay = min(max(delay * 2, Self.initialDelay), Self.maximumDelay)
                }
            }
        }
        pending[serverID] = Pending(generation: generation, probe: probe, task: task)
    }

    private func recovered(_ serverID: UUID, generation: UUID) async {
        // A probe restarted by the network, or ended by an operation that
        // succeeded, has nothing left to report.
        guard pending[serverID]?.generation == generation else { return }
        pending[serverID] = nil
        await resolve()
    }

    private func resolve() async {
        if pending.isEmpty {
            monitor?.cancel()
            monitor = nil
            networkWasAvailable = nil
        }
        do {
            let manager = try FinderDomain.manager()
            try await manager.signalErrorResolved(NSFileProviderError(.serverUnreachable) as NSError)
            try await FinderDomain.signalWorkingSet()
            Self.log.notice("Signalled that unreachable servers are reachable again")
        } catch {
            Self.log.error("Could not signal that the server is reachable again: \(error.localizedDescription)")
        }
    }

    private func startMonitoringNetwork() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let isAvailable = path.status == .satisfied
            Task { await self?.networkChanged(isAvailable: isAvailable) }
        }
        monitor.start(queue: DispatchQueue(label: "dev.hamasen.server-recovery"))
        self.monitor = monitor
    }

    private func networkChanged(isAvailable: Bool) {
        defer { networkWasAvailable = isAvailable }
        guard isAvailable, networkWasAvailable == false else { return }
        for (serverID, running) in pending {
            running.task.cancel()
            schedule(serverID, probe: running.probe, firstDelay: .zero)
        }
    }
}
