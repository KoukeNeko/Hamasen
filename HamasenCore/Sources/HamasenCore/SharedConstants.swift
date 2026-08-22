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

/// Identifiers shared between the main app and the File Provider extension,
/// kept in one place so they cannot drift apart.
public enum SharedConstants {
    /// App Group for shared files and defaults. Must match the application
    /// groups entitlement of every target.
    ///
    /// The macOS team-prefixed form, not "group.*": a team-prefixed group is
    /// validated against the signing certificate alone, so the Developer ID
    /// builds used for distribution need no provisioning profile.
    public static let appGroupIdentifier = "33832Z66QU.group.dev.hamasen.shared"


    /// Service name for Keychain items.
    public static let keychainService = "dev.hamasen.credentials"

    /// The Keychain access group the app and the File Provider extension
    /// share, so the extension can read the credentials it connects with.
    public static let keychainAccessGroup = "33832Z66QU.dev.hamasen.credentials"

    /// Data Protection Keychain groups used only as migration sources. New
    /// credentials use the file-based Keychain with an explicit item ACL.
    public static let migratedKeychainAccessGroupIdentifiers = [
        "group.dev.hamasen.shared",
        "33832Z66QU.group.dev.hamasen.shared",
        "33832Z66QU.dev.hamasen.credentials",
    ]

    /// File name of the server config store inside the App Group container.
    public static let serverConfigFileName = "servers.json"

    /// File name of the mounted-server set inside the App Group container.
    public static let mountedServersFileName = "mounted-servers.json"

    /// File name of the set of items the user pinned to this Mac.
    public static let pinnedItemsFileName = "pinned-items.json"
    /// The host keys each endpoint has presented, so a changed one can be
    /// told from a first sighting.
    public static let knownHostsFileName = "known-hosts.json"

    /// The single File Provider domain. Every server appears as a top-level
    /// folder inside it, so Finder shows one Hamasen location. The sidebar
    /// label comes from the app's localized display name (哈瑪星 / Hamasen);
    /// this constant stays ASCII because it also names the CloudStorage
    /// folder on disk.
    public static let mainDomainIdentifier = "dev.hamasen.main"
    public static let mainDomainDisplayName = "Hamasen"
}
