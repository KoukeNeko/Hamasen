import Foundation

/// Persistence for server configurations: a JSON file in the App Group
/// container, readable by both the app and the extension.
public struct ServerConfigStore: Sendable {
    public enum StoreError: Error {
        case appGroupContainerUnavailable(groupIdentifier: String)
    }

    private let fileURL: URL

    /// Standard initializer backed by the App Group container (used by both
    /// the app and the extension).
    public init(appGroupIdentifier: String = SharedConstants.appGroupIdentifier) throws {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw StoreError.appGroupContainerUnavailable(groupIdentifier: appGroupIdentifier)
        }
        self.fileURL = containerURL.appendingPathComponent(SharedConstants.serverConfigFileName)
    }

    /// Test initializer: uses an arbitrary file location, independent of any
    /// App Group.
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func loadServers() throws -> [ServerConfig] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([ServerConfig].self, from: data)
    }

    public func saveServers(_ servers: [ServerConfig]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(servers)
        try data.write(to: fileURL, options: .atomic)
    }

    public func server(withID id: UUID) throws -> ServerConfig? {
        try loadServers().first { $0.id == id }
    }
}
