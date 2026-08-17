import Foundation

/// One materialized file, reduced to what deciding its fate needs.
public struct CachedItem: Equatable, Sendable {
    public let identifier: String
    public let serverID: UUID
    public let byteCount: Int64
    /// Used to choose what goes first. The system does not tell a provider
    /// when an item was last read, so the newest content is kept and the
    /// stalest is dropped.
    public let modifiedAt: Date?

    public init(identifier: String, serverID: UUID, byteCount: Int64, modifiedAt: Date?) {
        self.identifier = identifier
        self.serverID = serverID
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
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
    ///   - limit: the most identifiers to return, so one pass cannot run
    ///     unboundedly on a large mount.
    public static func itemsToEvict(
        from items: [CachedItem],
        policies: [UUID: CachePolicy],
        limit: Int
    ) -> [String] {
        guard limit > 0 else { return [] }

        var planned: [String] = []
        for (serverID, policy) in policies.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            // Stalest first: an item with no date is treated as the stalest,
            // since nothing suggests it is still wanted.
            let owned = items
                .filter { $0.serverID == serverID }
                .sorted { lhs, rhs in
                    (lhs.modifiedAt ?? .distantPast) < (rhs.modifiedAt ?? .distantPast)
                }

            switch policy {
            case .unlimited:
                continue
            case .keepNothing:
                planned.append(contentsOf: owned.map(\.identifier))
            case .keepUpTo(let allowance):
                var excess = owned.reduce(Int64(0)) { $0 + $1.byteCount } - allowance
                guard excess > 0 else { continue }
                for item in owned where excess > 0 {
                    planned.append(item.identifier)
                    excess -= item.byteCount
                }
            }
        }
        return Array(planned.prefix(limit))
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
