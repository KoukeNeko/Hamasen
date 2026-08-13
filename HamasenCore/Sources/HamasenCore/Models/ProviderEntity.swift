import FileProvider
import Foundation

/// What an NSFileProviderItemIdentifier points at in the single-domain world:
/// the domain root (listing all servers), one server's root folder, or an
/// item inside a server.
///
/// Both the file provider and its UI extension read identifiers, so the
/// mapping lives here rather than in either extension.
public enum ProviderEntity: Equatable, Sendable {
    case root
    case serverRoot(UUID)
    case item(serverID: UUID, path: String)

    /// The server an entity belongs to, or nil for the domain root.
    public var serverID: UUID? {
        switch self {
        case .root:
            return nil
        case .serverRoot(let serverID), .item(let serverID, _):
            return serverID
        }
    }

    /// The path within the server, treating a server's root folder as "/".
    public var path: String {
        switch self {
        case .root, .serverRoot:
            return RemotePath.root
        case .item(_, let path):
            return path
        }
    }
}

/// Bidirectional mapping between identifiers and entities.
///
/// Format: "srv:<uuid>" is a server's root folder and "srv:<uuid>:<path>" an
/// item inside it. The UUID has a fixed length, so paths containing ":" are
/// parsed correctly by position.
public enum ItemIdentifierMapper {
    private static let serverPrefix = "srv:"
    private static let uuidStringLength = 36

    public static func entity(for identifier: NSFileProviderItemIdentifier) -> ProviderEntity? {
        switch identifier {
        case .rootContainer, .workingSet, .trashContainer:
            return .root
        default:
            break
        }

        let rawValue = identifier.rawValue
        guard rawValue.hasPrefix(serverPrefix) else { return nil }

        let afterPrefix = rawValue.dropFirst(serverPrefix.count)
        guard afterPrefix.count >= uuidStringLength,
              let serverID = UUID(uuidString: String(afterPrefix.prefix(uuidStringLength)))
        else { return nil }

        let afterUUID = afterPrefix.dropFirst(uuidStringLength)
        if afterUUID.isEmpty {
            return .serverRoot(serverID)
        }
        guard afterUUID.hasPrefix(":") else { return nil }
        let path = String(afterUUID.dropFirst())
        guard path.hasPrefix(RemotePath.root) else { return nil }
        return path == RemotePath.root ? .serverRoot(serverID) : .item(serverID: serverID, path: path)
    }

    public static func identifier(for entity: ProviderEntity) -> NSFileProviderItemIdentifier {
        switch entity {
        case .root:
            return .rootContainer
        case .serverRoot(let serverID):
            return NSFileProviderItemIdentifier("\(serverPrefix)\(serverID.uuidString)")
        case .item(let serverID, let path):
            return NSFileProviderItemIdentifier("\(serverPrefix)\(serverID.uuidString):\(path)")
        }
    }

    public static func parentEntity(of entity: ProviderEntity) -> ProviderEntity {
        switch entity {
        case .root, .serverRoot:
            return .root
        case .item(let serverID, let path):
            let parentPath = RemotePath.parent(of: path)
            return parentPath == RemotePath.root
                ? .serverRoot(serverID)
                : .item(serverID: serverID, path: parentPath)
        }
    }
}
