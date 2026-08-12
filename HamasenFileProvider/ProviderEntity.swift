import FileProvider
import Foundation
import HamasenCore

/// What an NSFileProviderItemIdentifier points at in the single-domain world:
/// the domain root (listing all servers), one server's root folder, or an
/// item inside a server.
enum ProviderEntity: Equatable {
    case root
    case serverRoot(UUID)
    case item(serverID: UUID, path: String)
}

/// Bidirectional mapping between identifiers and entities.
///
/// Format: "srv:<uuid>" is a server's root folder and "srv:<uuid>:<path>" an
/// item inside it. The UUID has a fixed length, so paths containing ":" are
/// parsed correctly by position.
enum ItemIdentifierMapper {
    private static let serverPrefix = "srv:"
    private static let uuidStringLength = 36

    static func entity(for identifier: NSFileProviderItemIdentifier) -> ProviderEntity? {
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

    static func identifier(for entity: ProviderEntity) -> NSFileProviderItemIdentifier {
        switch entity {
        case .root:
            return .rootContainer
        case .serverRoot(let serverID):
            return NSFileProviderItemIdentifier("\(serverPrefix)\(serverID.uuidString)")
        case .item(let serverID, let path):
            return NSFileProviderItemIdentifier("\(serverPrefix)\(serverID.uuidString):\(path)")
        }
    }

    static func parentEntity(of entity: ProviderEntity) -> ProviderEntity {
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
