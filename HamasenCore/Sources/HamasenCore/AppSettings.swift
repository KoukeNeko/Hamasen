import Foundation
import os

/// App-wide preferences shared between the app and the File Provider
/// extension through App Group UserDefaults.
///
/// App-only preferences (menu bar icon, Dock visibility, launch at login)
/// live in the app's standard defaults instead — the extension never needs
/// them.
public enum AppSettings {
    public enum Keys {
        public static let connectTimeoutSeconds = "connectTimeoutSeconds"
        public static let defaultServerPort = "defaultServerPort"
        public static let debugLoggingEnabled = "debugLoggingEnabled"
        /// Where the Finder location lives on disk, published by the app for
        /// the FinderSync extension (see FinderDomain.publishUserVisibleLocation).
        public static let mountRootPath = "mountRootPath"
    }

    public static let defaultConnectTimeoutSeconds = 30
    public static let connectTimeoutRange = 5...300

    /// The shared store; falls back to standard defaults when the App Group
    /// container is unavailable (e.g. in unit tests without entitlements).
    public static var sharedStore: UserDefaults {
        UserDefaults(suiteName: SharedConstants.appGroupIdentifier) ?? .standard
    }

    public static func connectTimeoutSeconds(from store: UserDefaults = sharedStore) -> Int {
        let storedValue = store.integer(forKey: Keys.connectTimeoutSeconds)
        guard connectTimeoutRange.contains(storedValue) else {
            return defaultConnectTimeoutSeconds
        }
        return storedValue
    }

    public static func defaultServerPort(from store: UserDefaults = sharedStore) -> Int {
        let storedValue = store.integer(forKey: Keys.defaultServerPort)
        guard (1...65535).contains(storedValue) else {
            return ServerConfig.defaultSFTPPort
        }
        return storedValue
    }

    public static func isDebugLoggingEnabled(from store: UserDefaults = sharedStore) -> Bool {
        store.bool(forKey: Keys.debugLoggingEnabled)
    }
}

/// Unified logging that honours the debug-logging preference. Visible in
/// Console.app under the dev.hamasen subsystem.
public struct HamasenLog: Sendable {
    private static let subsystem = "dev.hamasen"

    private let logger: Logger

    public init(category: String) {
        self.logger = Logger(subsystem: Self.subsystem, category: category)
    }

    /// Diagnostic detail; emitted only when the preference is on.
    public func debug(_ message: String) {
        guard AppSettings.isDebugLoggingEnabled() else { return }
        logger.debug("\(message, privacy: .public)")
    }

    /// Facts the user may need later (not failures), kept regardless of the
    /// preference — the notice level is persisted by default.
    public func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }

    /// Failures are always logged regardless of the preference.
    public func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
