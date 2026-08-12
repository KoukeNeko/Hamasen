import Foundation

/// Identifiers shared between the main app and the File Provider extension,
/// kept in one place so they cannot drift apart.
public enum SharedConstants {
    /// App Group: both the config file and Keychain sharing hang off this
    /// group. Must match the entitlements of both targets.
    public static let appGroupIdentifier = "group.dev.hamasen.shared"

    /// Service name for Keychain items.
    public static let keychainService = "dev.hamasen.credentials"

    /// File name of the server config store inside the App Group container.
    public static let serverConfigFileName = "servers.json"

    /// File name of the mounted-server set inside the App Group container.
    public static let mountedServersFileName = "mounted-servers.json"

    /// The single File Provider domain. Every server appears as a top-level
    /// folder inside it, so Finder shows one Hamasen location. The sidebar
    /// label comes from the app's localized display name (哈瑪星 / Hamasen);
    /// this constant stays ASCII because it also names the CloudStorage
    /// folder on disk.
    public static let mainDomainIdentifier = "dev.hamasen.main"
    public static let mainDomainDisplayName = "Hamasen"
}
