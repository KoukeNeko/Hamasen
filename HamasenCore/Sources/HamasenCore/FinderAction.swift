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

/// The entries Hamasen adds to the Finder context menu.
///
/// Finder builds that menu from the actions the File Provider extension
/// declares in its Info.plist (`NSExtensionFileProviderActions`) and hands
/// the chosen one back by identifier. The identifiers live here so the plist,
/// the extension, and the tests that pin the plist cannot drift apart.
public enum FinderAction: String, CaseIterable, Sendable {
    /// Puts "user@host:/remote/path" of one item on the clipboard.
    case copyRemotePath = "dev.hamasen.action.copyRemotePath"
    /// Puts the item's path on this Mac — the one under ~/Library/CloudStorage
    /// that local tools and scripts can open — on the clipboard.
    case copyLocalPath = "dev.hamasen.action.copyLocalPath"
    /// Asks the system to re-enumerate the mounted servers.
    case refresh = "dev.hamasen.action.refresh"
    /// Removes a server from Finder; only offered on a server's own folder.
    case unmountServer = "dev.hamasen.action.unmountServer"
    /// Evicts the local copies of the selection so they become dataless again.
    case freeLocalSpace = "dev.hamasen.action.freeLocalSpace"
    /// Keeps the selection on this Mac, exempt from the cache allowance.
    case keepOnMac = "dev.hamasen.action.keepOnMac"
    /// Lets the cache allowance drop the selection again.
    case stopKeepingOnMac = "dev.hamasen.action.stopKeepingOnMac"
    /// Puts the item's URL on the clipboard: its address on the server, or
    /// its web page on a cloud drive.
    case copyURL = "dev.hamasen.action.copyURL"
    /// Opens the item's web page; only on protocols that have one.
    case openInBrowser = "dev.hamasen.action.openInBrowser"
    /// Opens an SSH session to the server in Terminal; SFTP only.
    case openInTerminal = "dev.hamasen.action.openInTerminal"
    /// Brings the app forward on the item's connection.
    case showInHamasen = "dev.hamasen.action.showInHamasen"
}

/// The `hamasen://` links the app answers, so the extension, which cannot
/// show a window, can ask it to.
public enum AppLink {
    public static let scheme = "hamasen"
    private static let connectionHost = "connection"

    /// Opens the app on one connection's settings.
    public static func connection(_ serverID: UUID) -> URL {
        URL(string: "\(scheme)://\(connectionHost)/\(serverID.uuidString)")!
    }

    /// The connection a link names, or nil for any other link.
    public static func connectionID(in url: URL) -> UUID? {
        guard url.scheme == scheme, url.host() == connectionHost else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }
}
