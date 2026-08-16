import FileProvider
import Foundation

extension ServerConfig.StorageMode {
    /// How the system should treat the content of items in this server's
    /// folder.
    ///
    /// `.inherited` on a server folder means the domain root's policy applies,
    /// which on macOS keeps content until the disk is under pressure. Online
    /// only asks for the opposite bias: fetch on read, and drop the copy as
    /// soon as the server's version moves on. Items inside a server folder
    /// always inherit, so one value covers a whole server.
    public var contentPolicy: NSFileProviderContentPolicy {
        switch self {
        case .automatic:
            return .inherited
        case .onlineOnly:
            return .downloadLazilyAndEvictOnRemoteUpdate
        }
    }

    /// Distinguishes the modes inside an item version, so that changing the
    /// mode reaches the system: without it a server folder looks unchanged
    /// and the old policy stays in force until something else re-enumerates.
    public var versionToken: String {
        rawValue
    }
}
