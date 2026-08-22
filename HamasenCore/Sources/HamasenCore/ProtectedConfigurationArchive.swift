import Foundation

/// A configuration together with the secrets that go with it.
///
/// A separate type from ``ConfigurationArchive`` rather than an optional
/// field on it, so a plain export cannot carry a credential even by mistake:
/// the type it writes has nowhere to put one. This one only ever exists
/// inside an ``EncryptedArchive``.
public struct ProtectedConfigurationArchive: Codable, Equatable, Sendable {
    public let configuration: ConfigurationArchive
    public let credentials: [Credential]

    /// One stored secret, named by the server it belongs to in the archive.
    /// The identifier is the archive's, which a restore has to translate:
    /// restored servers are given fresh ones.
    public struct Credential: Codable, Equatable, Sendable {
        public let serverID: UUID
        public let kind: String
        public let secret: String

        public init(serverID: UUID, kind: String, secret: String) {
            self.serverID = serverID
            self.kind = kind
            self.secret = secret
        }
    }

    public init(configuration: ConfigurationArchive, credentials: [Credential]) {
        self.configuration = configuration
        self.credentials = credentials
    }

    /// Seals the whole thing, so the server list is no more readable than the
    /// passwords are. Which servers someone has is worth protecting too.
    public func sealed(passphrase: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let archive = try EncryptedArchive.seal(try encoder.encode(self), passphrase: passphrase)

        let envelopeEncoder = JSONEncoder()
        envelopeEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try envelopeEncoder.encode(archive)
    }

    public static func opened(_ data: Data, passphrase: String) throws -> ProtectedConfigurationArchive {
        guard let envelope = try? JSONDecoder().decode(EncryptedArchive.self, from: data) else {
            throw ConfigurationArchive.ArchiveError.unreadable
        }
        // Unsealed on its own line: folding it into the decode would let a
        // wrong passphrase be reported as an unreadable file, which sends
        // whoever mistyped it looking for a damaged backup.
        let contents = try envelope.opened(passphrase: passphrase)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let archive = try? decoder.decode(ProtectedConfigurationArchive.self, from: contents) else {
            throw ConfigurationArchive.ArchiveError.unreadable
        }
        guard archive.configuration.version <= ConfigurationArchive.currentVersion else {
            throw ConfigurationArchive.ArchiveError.unsupportedVersion(
                found: archive.configuration.version,
                supported: ConfigurationArchive.currentVersion
            )
        }
        return archive
    }

    /// Whether a file is one of these rather than a plain export, so the
    /// import can ask for a passphrase only when there is something to
    /// unlock.
    public static func isProtected(_ data: Data) -> Bool {
        (try? JSONDecoder().decode(EncryptedArchive.self, from: data)) != nil
    }

    /// The credentials to write after a restore, renamed to the identifiers
    /// the restored servers were actually given.
    ///
    /// Anything belonging to a server the restore skipped is dropped: that
    /// server is already configured here, and replacing the password it is
    /// working with would be a surprising thing for a restore to do.
    public func credentials(
        remappedBy remapping: [UUID: UUID]
    ) -> [Credential] {
        credentials.compactMap { credential in
            guard let restoredID = remapping[credential.serverID] else { return nil }
            return Credential(serverID: restoredID, kind: credential.kind, secret: credential.secret)
        }
    }
}
