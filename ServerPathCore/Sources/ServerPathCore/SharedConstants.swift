import Foundation

/// Identifiers shared between the main app and the File Provider extension,
/// kept in one place so they cannot drift apart.
public enum SharedConstants {
    /// App Group: both the config file and Keychain sharing hang off this
    /// group. Must match the entitlements of both targets.
    public static let appGroupIdentifier = "group.dev.serverpath.shared"

    /// Service name for Keychain items.
    public static let keychainService = "dev.serverpath.credentials"

    /// File name of the server config store inside the App Group container.
    public static let serverConfigFileName = "servers.json"

    /// File name of the mounted-server set inside the App Group container.
    public static let mountedServersFileName = "mounted-servers.json"

    /// The single File Provider domain. Every server appears as a top-level
    /// folder inside it, so Finder shows one "Server Path" location.
    public static let mainDomainIdentifier = "dev.serverpath.main"
    public static let mainDomainDisplayName = "Server Path"
}
