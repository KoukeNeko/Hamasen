import Foundation

/// Persists which servers are currently shown in Finder (mounted), separate
/// from the server configurations so no Codable migration is needed.
/// Written by the app, read by the File Provider extension.
public struct MountedServersStore: Sendable {
    private let fileURL: URL

    /// Standard initializer backed by the App Group container.
    public init(appGroupIdentifier: String = SharedConstants.appGroupIdentifier) throws {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw ServerConfigStore.StoreError.appGroupContainerUnavailable(groupIdentifier: appGroupIdentifier)
        }
        self.fileURL = containerURL.appendingPathComponent(SharedConstants.mountedServersFileName)
    }

    /// Test initializer: uses an arbitrary file location.
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func loadMountedServerIDs() throws -> Set<UUID> {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(Set<UUID>.self, from: data)
    }

    public func saveMountedServerIDs(_ serverIDs: Set<UUID>) throws {
        let data = try JSONEncoder().encode(serverIDs)
        try data.write(to: fileURL, options: .atomic)
    }
}
