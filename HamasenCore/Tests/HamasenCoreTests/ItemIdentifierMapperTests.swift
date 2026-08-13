import FileProvider
import Foundation
import Testing
@testable import HamasenCore

/// The file provider and its UI extension both decode identifiers, so the
/// format has to survive every path a real server can produce.
@Suite("ItemIdentifierMapper")
struct ItemIdentifierMapperTests {
    private static let serverID = UUID(uuidString: "1E1AC5B4-9E5E-4C0E-9E43-8E4E2E7F0A11")!

    @Test("系統容器都視為根目錄")
    func mapsSystemContainersToRoot() {
        for identifier in [NSFileProviderItemIdentifier.rootContainer, .workingSet, .trashContainer] {
            #expect(ItemIdentifierMapper.entity(for: identifier) == .root)
        }
    }

    @Test("伺服器資料夾與內部項目來回轉換皆相同")
    func roundTripsEntities() {
        let entities: [ProviderEntity] = [
            .serverRoot(Self.serverID),
            .item(serverID: Self.serverID, path: "/docs/report.txt"),
            .item(serverID: Self.serverID, path: "/a b/+&#?.txt"),
        ]

        for entity in entities {
            let identifier = ItemIdentifierMapper.identifier(for: entity)
            #expect(ItemIdentifierMapper.entity(for: identifier) == entity)
        }
    }

    @Test("路徑含冒號時仍依位置正確解析")
    func parsesPathsContainingColons() {
        let entity = ProviderEntity.item(serverID: Self.serverID, path: "/logs/12:30:00.log")
        let identifier = ItemIdentifierMapper.identifier(for: entity)

        #expect(ItemIdentifierMapper.entity(for: identifier) == entity)
    }

    @Test("伺服器根目錄的路徑等同於 /")
    func treatsServerRootPathAsRoot() {
        let identifier = NSFileProviderItemIdentifier("srv:\(Self.serverID.uuidString):/")

        #expect(ItemIdentifierMapper.entity(for: identifier) == .serverRoot(Self.serverID))
    }

    @Test("非 Hamasen 或格式錯誤的識別碼回傳 nil")
    func rejectsForeignIdentifiers() {
        let invalid = [
            "other:123",
            "srv:not-a-uuid-at-all-not-a-uuid-at-all",
            "srv:\(Self.serverID.uuidString)/docs",  // missing the ":" separator
            "srv:\(Self.serverID.uuidString):docs",  // path is not absolute
            "srv:",
        ]

        for rawValue in invalid {
            #expect(
                ItemIdentifierMapper.entity(for: NSFileProviderItemIdentifier(rawValue)) == nil,
                "應拒絕 \(rawValue)"
            )
        }
    }

    @Test("entity 可取出所屬伺服器與路徑")
    func exposesServerAndPath() {
        #expect(ProviderEntity.root.serverID == nil)
        #expect(ProviderEntity.root.path == RemotePath.root)
        #expect(ProviderEntity.serverRoot(Self.serverID).serverID == Self.serverID)
        #expect(ProviderEntity.serverRoot(Self.serverID).path == RemotePath.root)

        let nested = ProviderEntity.item(serverID: Self.serverID, path: "/a/b.txt")
        #expect(nested.serverID == Self.serverID)
        #expect(nested.path == "/a/b.txt")
    }

    @Test("父層由項目逐級回到根目錄")
    func walksUpToRoot() {
        let deep = ProviderEntity.item(serverID: Self.serverID, path: "/a/b/c.txt")
        let middle = ItemIdentifierMapper.parentEntity(of: deep)
        #expect(middle == .item(serverID: Self.serverID, path: "/a/b"))

        let top = ItemIdentifierMapper.parentEntity(of: .item(serverID: Self.serverID, path: "/a"))
        #expect(top == .serverRoot(Self.serverID))
        #expect(ItemIdentifierMapper.parentEntity(of: .serverRoot(Self.serverID)) == .root)
        #expect(ItemIdentifierMapper.parentEntity(of: .root) == .root)
    }
}
