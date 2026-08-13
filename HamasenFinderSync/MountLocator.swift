import FileProvider
import Foundation
import HamasenCore

/// A file inside the Hamasen mount, resolved back to the server it came from.
struct MountedLocation {
    let server: ServerConfig
    /// Path within the server, as `RemotePath` expresses it.
    let path: String

    var isServerRoot: Bool { path == RemotePath.root }
}

/// Translates local Finder URLs back into servers and remote paths.
///
/// Finder hands a FinderSync extension plain file URLs under
/// `~/Library/CloudStorage`, with no item identifiers, so the mapping has to
/// be rebuilt from the path: the first component under the mount is the
/// server's folder, which the provider names after the server.
enum MountLocator {
    static func location(of url: URL, under root: URL) -> MountedLocation? {
        guard let components = pathComponents(of: url, under: root),
              let serverName = components.first,
              let server = try? ServerConfigStore().loadServers()
                  .first(where: { $0.name == serverName })
        else { return nil }

        let pathInServer = components.dropFirst()
        guard !pathInServer.isEmpty else {
            return MountedLocation(server: server, path: RemotePath.root)
        }
        return MountedLocation(
            server: server,
            path: RemotePath.root + pathInServer.joined(separator: RemotePath.separator)
        )
    }

    /// The components of `url` below `root`, or nil if it is not inside it.
    private static func pathComponents(of url: URL, under root: URL) -> [String]? {
        let rootComponents = root.standardizedFileURL.pathComponents
        let urlComponents = url.standardizedFileURL.pathComponents

        guard urlComponents.count > rootComponents.count,
              Array(urlComponents.prefix(rootComponents.count)) == rootComponents
        else { return nil }

        return Array(urlComponents.dropFirst(rootComponents.count))
    }
}
