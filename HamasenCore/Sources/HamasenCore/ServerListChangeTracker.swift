import Foundation

/// Tracks what changed in the mounted-server list between two enumerations.
///
/// The File Provider extension has no state of its own between calls, so the
/// previous list is carried inside the sync anchor the system hands back.
public enum ServerListChangeTracker {
    /// Server identifier to display name; enough to detect additions,
    /// removals, and renames, which are the only changes Finder can see at
    /// the top level.
    public typealias Snapshot = [String: String]

    public struct Diff: Equatable, Sendable {
        /// Servers that appeared or were renamed.
        public let updated: [ServerConfig]
        /// Servers that are no longer mounted.
        public let removedServerIDs: [String]

        public var isEmpty: Bool { updated.isEmpty && removedServerIDs.isEmpty }
    }

    public static func snapshot(of configs: [ServerConfig]) -> Snapshot {
        Dictionary(configs.map { ($0.id.uuidString, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    /// Encodes a snapshot for use as a sync anchor. Sorted keys keep the
    /// encoding stable so an unchanged list produces an identical anchor.
    public static func encode(_ snapshot: Snapshot) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(snapshot)) ?? Data()
    }

    /// Decodes a previously encoded snapshot; an unreadable anchor is treated
    /// as "nothing known yet", which makes every server look new.
    public static func decode(_ data: Data) -> Snapshot {
        (try? JSONDecoder().decode(Snapshot.self, from: data)) ?? [:]
    }

    public static func diff(previous: Snapshot, current configs: [ServerConfig]) -> Diff {
        let current = snapshot(of: configs)
        let updated = configs.filter { previous[$0.id.uuidString] != $0.name }
        let removedServerIDs = previous.keys.filter { current[$0] == nil }.sorted()
        return Diff(updated: updated, removedServerIDs: removedServerIDs)
    }
}
