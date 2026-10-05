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

import Foundation

/// One materialized file, reduced to what deciding its fate needs.
public struct CachedItem: Equatable, Sendable {
    public let identifier: String
    public let serverID: UUID
    public let byteCount: Int64
    /// When the content last changed on the server.
    public let modifiedAt: Date?
    /// When the file was last opened, downloaded, or first seen on this Mac,
    /// whichever is latest — the best answer there is to "when was this last
    /// wanted". See `ItemUsageStore`.
    public let lastUsedAt: Date?

    public init(
        identifier: String, serverID: UUID, byteCount: Int64, modifiedAt: Date?, lastUsedAt: Date? = nil
    ) {
        self.identifier = identifier
        self.serverID = serverID
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
        self.lastUsedAt = lastUsedAt
    }

    /// What decides which item goes first: when it was last wanted, or, for
    /// an item with no record of that, when it last changed.
    var staleness: Date {
        lastUsedAt ?? modifiedAt ?? .distantPast
    }
}

/// How much of a server's content may stay on this Mac.
public enum CachePolicy: Equatable, Sendable {
    /// Keep nothing that is no longer needed.
    case keepNothing
    /// Keep up to a number of bytes, dropping the stalest content first.
    case keepUpTo(bytes: Int64)
    /// Leave it to the system, which reclaims space only under pressure.
    case unlimited
}

/// Chooses which cached files to drop, given each server's policy.
///
/// Kept apart from the eviction itself so the decision — the part with the
/// edge cases — can be tested without a File Provider domain.
public enum CacheEvictionPlan {
    /// Items to evict, stalest first within each server.
    ///
    /// - Parameters:
    ///   - items: every materialized file, from any server.
    ///   - policies: the policy per server. A server absent from this map is
    ///     not managed, and nothing of it is dropped.
    ///   - pinned: identifiers the user asked to keep, which no allowance
    ///     may drop. A limit says how much to keep, not what.
    ///   - limit: the most identifiers to return, so one pass cannot run
    ///     unboundedly on a large mount.
    public static func itemsToEvict(
        from items: [CachedItem],
        policies: [UUID: CachePolicy],
        pinned: Set<String> = [],
        limit: Int
    ) -> [String] {
        guard limit > 0 else { return [] }

        var planned: [String] = []
        for (serverID, policy) in policies.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            // Stalest first: an item with no date is treated as the stalest,
            // since nothing suggests it is still wanted.
            let owned = items
                .filter { $0.serverID == serverID && !pinned.contains($0.identifier) }
                .sorted { $0.staleness < $1.staleness }

            switch policy {
            case .unlimited:
                continue
            case .keepNothing:
                planned.append(contentsOf: owned.map(\.identifier))
            case .keepUpTo(let allowance):
                let pinnedBytes = items
                    .filter { $0.serverID == serverID && pinned.contains($0.identifier) }
                    .reduce(Int64(0)) { $0 + $1.byteCount }
                var excess = owned.reduce(pinnedBytes) { $0 + $1.byteCount } - allowance
                guard excess > 0 else { continue }
                for item in owned where excess > 0 {
                    planned.append(item.identifier)
                    excess -= item.byteCount
                }
            }
        }
        return Array(planned.prefix(limit))
    }

    /// How far a server's pinned content alone puts it over its allowance.
    ///
    /// This is the one case a sweep cannot resolve: everything else has been
    /// dropped and the server is still over, because the user asked for that
    /// content to stay. Reporting it is the only remedy — the alternative is
    /// a limit that silently does not hold.
    public static func serversHeldOverAllowanceByPins(
        items: [CachedItem],
        policies: [UUID: CachePolicy],
        pinned: Set<String>
    ) -> [UUID: PinnedOverage] {
        var overages: [UUID: PinnedOverage] = [:]
        for (serverID, policy) in policies {
            guard case .keepUpTo(let allowance) = policy else { continue }
            let pinnedBytes = items
                .filter { $0.serverID == serverID && pinned.contains($0.identifier) }
                .reduce(Int64(0)) { $0 + $1.byteCount }
            guard pinnedBytes > allowance else { continue }
            overages[serverID] = PinnedOverage(pinnedBytes: pinnedBytes, allowanceBytes: allowance)
        }
        return overages
    }
}

/// What one server is holding on this Mac, split by what may be dropped.
public struct CacheUsage: Equatable, Sendable {
    /// Kept at the user's request; an allowance cannot drop these.
    public let pinnedBytes: Int64
    /// Cached, and free to go when the allowance calls for it.
    public let evictableBytes: Int64

    public var totalBytes: Int64 { pinnedBytes + evictableBytes }

    public init(pinnedBytes: Int64, evictableBytes: Int64) {
        self.pinnedBytes = pinnedBytes
        self.evictableBytes = evictableBytes
    }
}

extension CacheEvictionPlan {
    /// What each server is holding, for showing rather than for deciding.
    public static func usage(
        of items: [CachedItem],
        pinned: Set<String>
    ) -> [UUID: CacheUsage] {
        var pinnedBytes: [UUID: Int64] = [:]
        var evictableBytes: [UUID: Int64] = [:]
        for item in items {
            if pinned.contains(item.identifier) {
                pinnedBytes[item.serverID, default: 0] += item.byteCount
            } else {
                evictableBytes[item.serverID, default: 0] += item.byteCount
            }
        }
        let serverIDs = Set(pinnedBytes.keys).union(evictableBytes.keys)
        return Dictionary(uniqueKeysWithValues: serverIDs.map { serverID in
            (
                serverID,
                CacheUsage(
                    pinnedBytes: pinnedBytes[serverID] ?? 0,
                    evictableBytes: evictableBytes[serverID] ?? 0
                )
            )
        })
    }
}

/// A server kept over its allowance by what the user pinned.
public struct PinnedOverage: Equatable, Sendable {
    public let pinnedBytes: Int64
    public let allowanceBytes: Int64

    public init(pinnedBytes: Int64, allowanceBytes: Int64) {
        self.pinnedBytes = pinnedBytes
        self.allowanceBytes = allowanceBytes
    }
}

extension ServerConfig {
    /// What may stay on this Mac for this server.
    ///
    /// Online only wins over any allowance: a limit describes how much to
    /// keep, and that mode keeps nothing.
    public var cachePolicy: CachePolicy {
        switch storageMode {
        case .onlineOnly:
            return .keepNothing
        case .automatic:
            return cacheLimitBytes.map(CachePolicy.keepUpTo) ?? .unlimited
        }
    }
}

/// The allowances the settings offer.
///
/// Presets rather than a free byte field: the exact number does not matter,
/// and a text field would need validation for a choice with three sensible
/// answers.
public enum CacheAllowance: Int64, CaseIterable, Sendable, Identifiable {
    case unlimited = 0
    case oneGigabyte = 1_000_000_000
    case fiveGigabytes = 5_000_000_000
    case twentyGigabytes = 20_000_000_000
    case hundredGigabytes = 100_000_000_000

    public var id: Int64 { rawValue }

    public init(bytes: Int64?) {
        self = Self.allCases.first { $0.rawValue == bytes } ?? .unlimited
    }

    public var bytes: Int64? { self == .unlimited ? nil : rawValue }

    public var displayName: String {
        guard let bytes else { return String(localized: "不限制", bundle: .module) }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Automatic cleaning

/// The policy every mounted server shares: drop local copies nobody has
/// used for a while, and keep the total under a ceiling.
///
/// It sits on top of each server's own storage mode and allowance, which
/// still apply; whichever asks for more to go wins.
public struct AutoCleanPolicy: Equatable, Sendable {
    /// Days without use after which a copy goes.
    public let unusedDays: Int
    /// The most all servers together may hold; nil for no ceiling.
    public let totalLimitBytes: Int64?

    public init(unusedDays: Int, totalLimitBytes: Int64?) {
        self.unusedDays = unusedDays
        self.totalLimitBytes = totalLimitBytes
    }
}

extension CacheEvictionPlan {
    /// What the shared policy drops: everything unused for longer than it
    /// allows, then, stalest first, whatever still keeps the total over the
    /// ceiling. Pinned items are neither dropped nor, since nothing can be
    /// done about them, a reason to drop more than the rest.
    ///
    /// An item with no record of use is never dropped for age: a date of
    /// last change on the server says nothing about whether it was opened
    /// here yesterday.
    public static func itemsToClean(
        from items: [CachedItem],
        policy: AutoCleanPolicy,
        pinned: Set<String> = [],
        now: Date = Date(),
        limit: Int
    ) -> [String] {
        guard limit > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-TimeInterval(policy.unusedDays) * 86_400)
        let candidates = items
            .filter { !pinned.contains($0.identifier) }
            .sorted { $0.staleness < $1.staleness }

        var planned: [String] = []
        var dropped = Set<String>()
        for item in candidates {
            guard let lastUsedAt = item.lastUsedAt, lastUsedAt < cutoff else { continue }
            planned.append(item.identifier)
            dropped.insert(item.identifier)
        }

        if let ceiling = policy.totalLimitBytes {
            var total = items
                .filter { !dropped.contains($0.identifier) }
                .reduce(Int64(0)) { $0 + $1.byteCount }
            for item in candidates where total > ceiling && !dropped.contains(item.identifier) {
                planned.append(item.identifier)
                total -= item.byteCount
            }
        }
        return Array(planned.prefix(limit))
    }

    /// Every evictable item, for "remove all downloads".
    public static func allEvictable(from items: [CachedItem], pinned: Set<String>) -> [String] {
        items.filter { !pinned.contains($0.identifier) }.map(\.identifier)
    }
}

/// The idle periods Settings offers.
public enum AutoCleanUnusedDays: Int, CaseIterable, Sendable, Identifiable {
    case oneDay = 1
    case threeDays = 3
    case sevenDays = 7
    case fourteenDays = 14
    case thirtyDays = 30
    case ninetyDays = 90

    public var id: Int { rawValue }

    public init(days: Int) {
        self = Self(rawValue: days) ?? .sevenDays
    }

    public var displayName: String {
        Duration.seconds(rawValue * 86_400).formatted(.units(allowed: [.days], width: .wide))
    }
}

/// The ceilings Settings offers for everything the mounted servers hold.
public enum AutoCleanTotalLimit: Int64, CaseIterable, Sendable, Identifiable {
    case unlimited = 0
    case oneGigabyte = 1_000_000_000
    case fiveGigabytes = 5_000_000_000
    case tenGigabytes = 10_000_000_000
    case twentyGigabytes = 20_000_000_000
    case fiftyGigabytes = 50_000_000_000
    case hundredGigabytes = 100_000_000_000

    public var id: Int64 { rawValue }

    public init(bytes: Int64?) {
        self = Self.allCases.first { $0.rawValue == bytes ?? 0 } ?? .tenGigabytes
    }

    public var bytes: Int64? { self == .unlimited ? nil : rawValue }

    public var displayName: String {
        guard let bytes else { return String(localized: "不限制", bundle: .module) }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
