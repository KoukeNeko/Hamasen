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
        /// Whether the user has been told that content stored before the
        /// online-only mode existed can only be freed by remounting.
        public static let hasShownRemountForOnlineOnly = "hasShownRemountForOnlineOnly"
        public static let s3MultipartThresholdBytes = "s3MultipartThresholdBytes"
        public static let s3PartSizeBytes = "s3PartSizeBytes"
        /// Which set of domain capabilities the registered domain was created
        /// with. See `FinderDomain.capabilityGeneration`.
        public static let domainCapabilityGeneration = "domainCapabilityGeneration"
        public static let indexingDepth = "indexingDepth"
        public static let indexingDirectoryLimit = "indexingDirectoryLimit"
    }

    public static let defaultConnectTimeoutSeconds = 30
    public static let connectTimeoutRange = 5...300

    private static let bytesPerMebibyte = 1024 * 1024

    /// Above this an upload is sent in parts. Below it a single request is
    /// fewer round trips and cannot leave an unfinished upload behind.
    public static let defaultS3MultipartThresholdBytes = 100 * bytesPerMebibyte
    public static let s3MultipartThresholdRange =
        (5 * bytesPerMebibyte)...(5 * 1024 * bytesPerMebibyte)

    public static let defaultS3PartSizeBytes = 16 * bytesPerMebibyte
    /// S3's own bounds: no part below 5 MiB except the last, none above 5 GiB.
    public static let s3PartSizeRange = (5 * bytesPerMebibyte)...(5 * 1024 * bytesPerMebibyte)

    /// The largest file that can be uploaded at the given part size, because
    /// one upload is capped at this many parts. Shown next to the setting:
    /// a smaller part size silently lowers this ceiling, and the failure it
    /// eventually causes says nothing about why.
    public static let s3MaximumParts = 10_000

    public static func s3LargestUploadableBytes(partSizeBytes: Int) -> Int {
        partSizeBytes * s3MaximumParts
    }

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

    /// How far down the background walk goes, and how many directories it
    /// lists in one walk. Each directory is a request — billed on S3, load on
    /// anything else — so both are bounded and both can be set.
    public static let defaultIndexingDepth = WorkingSetWalk.Limits.default.maximumDepth
    public static let indexingDepthRange = 1...20
    public static let defaultIndexingDirectoryLimit = WorkingSetWalk.Limits.default.maximumDirectories
    public static let indexingDirectoryLimitRange = 50...50_000

    public static func indexingLimits(from store: UserDefaults = sharedStore) -> WorkingSetWalk.Limits {
        let depth = store.integer(forKey: Keys.indexingDepth)
        let directories = store.integer(forKey: Keys.indexingDirectoryLimit)
        return WorkingSetWalk.Limits(
            maximumDepth: indexingDepthRange.contains(depth) ? depth : defaultIndexingDepth,
            maximumDirectories: indexingDirectoryLimitRange.contains(directories)
                ? directories : defaultIndexingDirectoryLimit)
    }

    public static func s3PartSizeBytes(from store: UserDefaults = sharedStore) -> Int {
        let storedValue = store.integer(forKey: Keys.s3PartSizeBytes)
        guard s3PartSizeRange.contains(storedValue) else { return defaultS3PartSizeBytes }
        return storedValue
    }

    /// Never below the part size: a threshold under one part would send a
    /// single-part multipart upload, which is more requests for no gain.
    public static func s3MultipartThresholdBytes(from store: UserDefaults = sharedStore) -> Int {
        let partSize = s3PartSizeBytes(from: store)
        let storedValue = store.integer(forKey: Keys.s3MultipartThresholdBytes)
        guard s3MultipartThresholdRange.contains(storedValue) else {
            return max(defaultS3MultipartThresholdBytes, partSize)
        }
        return max(storedValue, partSize)
    }
}

/// The part sizes Settings offers.
///
/// A free number field would need its own validation for bounds nobody can
/// be expected to know — S3 refuses a part under 5 MiB except the last, and
/// one upload is capped at ten thousand parts.
public enum S3PartSize: Int, CaseIterable, Sendable, Identifiable {
    case fiveMebibytes = 5_242_880
    case eightMebibytes = 8_388_608
    case sixteenMebibytes = 16_777_216
    case thirtyTwoMebibytes = 33_554_432
    case sixtyFourMebibytes = 67_108_864
    case oneHundredTwentyEightMebibytes = 134_217_728

    public var id: Int { rawValue }

    public init(bytes: Int) {
        self = Self.allCases.first { $0.rawValue == bytes }
            ?? Self(rawValue: AppSettings.defaultS3PartSizeBytes)
            ?? .sixteenMebibytes
    }

    public var displayName: String {
        ByteCountFormatter.string(fromByteCount: Int64(rawValue), countStyle: .binary)
    }

    /// The largest file this part size can upload, since one upload is
    /// capped at ten thousand parts. Shrinking the part size lowers it, and
    /// the failure that eventually causes explains nothing.
    public var largestUploadDisplayName: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(AppSettings.s3LargestUploadableBytes(partSizeBytes: rawValue)),
            countStyle: .binary)
    }
}

/// The sizes above which Settings offers to switch to a multipart upload.
public enum S3MultipartThreshold: Int, CaseIterable, Sendable, Identifiable {
    case sixteenMebibytes = 16_777_216
    case fiftyMebibytes = 52_428_800
    case oneHundredMebibytes = 104_857_600
    case fiveHundredMebibytes = 524_288_000
    case oneGibibyte = 1_073_741_824

    public var id: Int { rawValue }

    public init(bytes: Int) {
        self = Self.allCases.first { $0.rawValue == bytes }
            ?? Self(rawValue: AppSettings.defaultS3MultipartThresholdBytes)
            ?? .oneHundredMebibytes
    }

    public var displayName: String {
        ByteCountFormatter.string(fromByteCount: Int64(rawValue), countStyle: .binary)
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
