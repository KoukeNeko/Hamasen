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

/// A configuration written down: the servers, the host keys recorded for
/// them, and the preferences that are not about this Mac in particular.
///
/// Credentials are deliberately absent. They were moved into the Keychain so
/// they would stop living in files, and this app already tells anyone
/// importing Cyberduck bookmarks that their passwords cannot come across —
/// its own export writing them out in the clear would be the same promise
/// broken in the other direction.
public struct ConfigurationArchive: Codable, Equatable, Sendable {
    /// Raised when a change would stop an older build reading a newer file.
    /// A build refuses what it cannot read rather than importing part of it.
    public static let currentVersion = 1

    public let version: Int
    public let exportedAt: Date
    public let servers: [ServerConfig]
    /// Fingerprints, which are public by nature — carrying them means a
    /// restored Mac already knows what its servers should look like, rather
    /// than trusting whatever answers first.
    public let knownHosts: KnownHosts
    public let settings: Settings

    /// The preferences worth carrying between Macs. What is about one Mac —
    /// the menu bar icon, the Dock icon, which servers are mounted — is not
    /// part of a configuration and stays behind.
    public struct Settings: Codable, Equatable, Sendable {
        public let connectTimeoutSeconds: Int
        public let defaultServerPort: Int

        public init(connectTimeoutSeconds: Int, defaultServerPort: Int) {
            self.connectTimeoutSeconds = connectTimeoutSeconds
            self.defaultServerPort = defaultServerPort
        }
    }

    public init(
        version: Int = ConfigurationArchive.currentVersion,
        exportedAt: Date,
        servers: [ServerConfig],
        knownHosts: KnownHosts,
        settings: Settings
    ) {
        self.version = version
        self.exportedAt = exportedAt
        self.servers = servers
        self.knownHosts = knownHosts
        self.settings = settings
    }
}

extension ConfigurationArchive {
    public enum ArchiveError: LocalizedError, Equatable {
        case unreadable
        case unsupportedVersion(found: Int, supported: Int)

        public var errorDescription: String? {
            switch self {
            case .unreadable:
                return String(localized: "這個檔案不是 Hamasen 的設定備份", bundle: .module)
            case .unsupportedVersion(let found, let supported):
                // Interpolated as text rather than as numbers so the catalog
                // key the compiler emits and the one generated from this call
                // site agree: a version is a label, not a quantity, and it
                // should never pick up a thousands separator either.
                return String(localized: "這份備份是較新版本（第 \(String(found)) 版，這個版本只讀到第 \(String(supported)) 版）建立的，請先更新 Hamasen", bundle: .module)
            }
        }
    }

    /// Pretty-printed with sorted keys: a backup people can read, and diff
    /// against an older one, is worth the few extra bytes.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decoded(from data: Data) throws -> ConfigurationArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let archive = try? decoder.decode(ConfigurationArchive.self, from: data) else {
            throw ArchiveError.unreadable
        }
        guard archive.version <= currentVersion else {
            throw ArchiveError.unsupportedVersion(found: archive.version, supported: currentVersion)
        }
        return archive
    }
}

extension ConfigurationArchive {
    /// What restoring this archive would add to what is already configured.
    public struct MergePlan: Equatable, Sendable {
        /// Servers to append, in the archive's order, minus the ones already
        /// present.
        public let servers: [ServerConfig]
        /// Servers the archive holds that are already configured here.
        public let duplicateCount: Int
        /// Which archived server became which restored one. Restored servers
        /// take fresh identifiers, so anything the archive keyed by the old
        /// one — its credentials — has to be renamed through this.
        public let identifierRemapping: [UUID: UUID]
        /// Host keys to record for endpoints nothing is known about. An
        /// endpoint already recorded is left alone: a backup must not be a
        /// way to quietly replace a key that stopped matching.
        public let knownHosts: KnownHosts

        public var isEmpty: Bool { servers.isEmpty && duplicateCount == 0 }
    }

    /// Merges rather than replaces. A restore that emptied the list first
    /// would turn "I imported the wrong file" into losing what was there.
    public func mergePlan(
        against existingServers: [ServerConfig],
        existingHosts: KnownHosts
    ) -> MergePlan {
        var seen = Set(existingServers.map(\.connectionIdentity))
        var toAdd: [ServerConfig] = []
        var remapping: [UUID: UUID] = [:]
        var duplicates = 0

        for server in servers {
            let identity = server.connectionIdentity
            if seen.contains(identity) {
                duplicates += 1
            } else {
                seen.insert(identity)
                // A fresh identifier, so restoring the same archive twice
                // cannot collide with what the first restore created.
                let restored = server.withNewIdentifier()
                remapping[server.id] = restored.id
                toAdd.append(restored)
            }
        }

        var hosts = existingHosts
        for endpoint in knownHosts.endpoints {
            guard let fingerprint = knownHosts.fingerprint(forEndpoint: endpoint) else { continue }
            hosts.recordIfUnknown(fingerprint, forEndpoint: endpoint)
        }

        return MergePlan(
            servers: toAdd,
            duplicateCount: duplicates,
            identifierRemapping: remapping,
            knownHosts: hosts
        )
    }
}

extension ServerConfig {
    /// The same server under a new identifier, so an import never reuses one
    /// that already names something here.
    func withNewIdentifier() -> ServerConfig {
        ServerConfig(
            name: name,
            transferProtocol: transferProtocol,
            host: host,
            port: port,
            username: username,
            authenticationMethod: authenticationMethod,
            remotePath: remotePath,
            storageMode: storageMode,
            cacheLimitBytes: cacheLimitBytes
        )
    }
}
