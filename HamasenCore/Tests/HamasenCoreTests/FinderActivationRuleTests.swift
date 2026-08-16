import FileProvider
import Foundation
import Testing
@testable import HamasenCore

/// Pins the Finder context-menu declaration in Config/HamasenFileProviderInfo.plist.
///
/// The system evaluates each `NSExtensionFileProviderActionActivationRule`
/// against a dictionary of `fileproviderItems` (the selection, as indexed
/// items) and `domainUserInfo`, and a rule that names anything else is
/// silently false — the entries then never appear and nothing logs an error.
/// These tests evaluate the shipped rules the same way, against selections
/// built from real identifiers, so a broken rule fails here instead of in
/// Finder.
@Suite("Finder activation rules")
struct FinderActivationRuleTests {
    private static let serverID = UUID(uuidString: "D43D14AD-BDCD-4EED-9A5D-8E2B33127075")!
    private static let otherServerID = UUID(uuidString: "1E1AC5B4-9E5E-4C0E-9E43-8E4E2E7F0A11")!

    /// An indexed item as the predicate context presents it; only the fields
    /// the shipped rules read are modelled.
    private struct IndexedItem {
        let identifier: NSFileProviderItemIdentifier
        let isFolder: Bool
        let isDownloaded: Bool

        static func folder(_ entity: ProviderEntity) -> IndexedItem {
            IndexedItem(identifier: ItemIdentifierMapper.identifier(for: entity), isFolder: true, isDownloaded: true)
        }

        static func file(_ entity: ProviderEntity, isDownloaded: Bool) -> IndexedItem {
            IndexedItem(identifier: ItemIdentifierMapper.identifier(for: entity), isFolder: false, isDownloaded: isDownloaded)
        }
    }

    private static let serverRoot = IndexedItem.folder(.serverRoot(serverID))
    private static let otherServerRoot = IndexedItem.folder(.serverRoot(otherServerID))
    private static let hamasenRoot = IndexedItem.folder(.root)
    private static let innerFolder = IndexedItem.folder(.item(serverID: serverID, path: "/docs"))
    private static let datalessFile = IndexedItem.file(
        .item(serverID: serverID, path: "/docs/report.txt"), isDownloaded: false
    )
    private static let downloadedFile = IndexedItem.file(
        .item(serverID: serverID, path: "/docs/notes.md"), isDownloaded: true
    )
    /// The system normalises this spelling to the server root; the rule has
    /// to accept it as well.
    private static let serverRootWithSlash = IndexedItem.folder(.item(serverID: serverID, path: RemotePath.root))

    /// Every selection the rules are expected to tell apart, with the
    /// entries each one must show.
    private static let expectations: [(selection: [IndexedItem], visible: Set<FinderAction>, label: String)] = [
        ([datalessFile], [.copyRemotePath, .refresh], "single dataless file"),
        ([downloadedFile], [.copyRemotePath, .refresh, .freeLocalSpace], "single downloaded file"),
        ([innerFolder], [.copyRemotePath, .refresh, .freeLocalSpace], "single folder"),
        ([serverRoot], [.copyRemotePath, .refresh, .unmountServer, .freeLocalSpace], "single server folder"),
        ([serverRootWithSlash], [.copyRemotePath, .refresh, .unmountServer, .freeLocalSpace], "server folder as srv:<uuid>:/"),
        ([datalessFile, downloadedFile], [.refresh, .freeLocalSpace], "two files, one downloaded"),
        ([datalessFile, innerFolder], [.refresh, .freeLocalSpace], "a file and a folder"),
        ([serverRoot, otherServerRoot], [.refresh, .freeLocalSpace], "two server folders"),
        ([hamasenRoot], [.refresh, .freeLocalSpace], "the Hamasen root"),
        ([], [], "nothing"),
    ]

    @Test("plist 宣告的 action 與 FinderAction 完全一致，且每條都有名稱與規則")
    func declaresExactlyTheKnownActions() throws {
        let actions = try Self.declaredActions()

        let declaredIdentifiers = Set(actions.map(\.identifier))
        #expect(declaredIdentifiers == Set(FinderAction.allCases.map(\.rawValue)))
        for action in actions {
            #expect(!action.name.isEmpty, "\(action.identifier) has no name key")
            #expect(!action.rule.isEmpty, "\(action.identifier) has no activation rule")
        }
    }

    @Test("每種選取都只顯示該顯示的項目")
    func rulesSelectTheRightEntries() throws {
        let actions = try Self.declaredActions()

        for expectation in Self.expectations {
            let context = Self.predicateContext(for: expectation.selection)
            for action in actions {
                let finderAction = try #require(FinderAction(rawValue: action.identifier))
                let isVisible = NSPredicate(format: action.rule).evaluate(with: context)
                #expect(
                    isVisible == expectation.visible.contains(finderAction),
                    "\(finderAction) for \(expectation.label): expected \(expectation.visible.contains(finderAction)), rule gave \(isVisible)"
                )
            }
        }
    }

    // MARK: - Fixtures

    private struct DeclaredAction {
        let identifier: String
        let name: String
        let rule: String
    }

    /// Reads the extension's Info.plist from the repository, so the test
    /// runs against what ships and not a copy of it.
    private static func declaredActions() throws -> [DeclaredAction] {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // HamasenCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // HamasenCore
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("Config/HamasenFileProviderInfo.plist")
        let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: plistURL), format: nil
        )
        let extensionInfo = try #require((plist as? [String: Any])?["NSExtension"] as? [String: Any])
        let entries = try #require(extensionInfo["NSExtensionFileProviderActions"] as? [[String: Any]])
        return try entries.map { entry in
            DeclaredAction(
                identifier: try #require(entry["NSExtensionFileProviderActionIdentifier"] as? String),
                name: try #require(entry["NSExtensionFileProviderActionName"] as? String),
                rule: try #require(entry["NSExtensionFileProviderActionActivationRule"] as? String)
            )
        }
    }

    /// The context `fileproviderctl evaluate` prints for a selection: an
    /// array of indexed items plus the domain's userInfo (empty for Hamasen).
    private static func predicateContext(for selection: [IndexedItem]) -> [String: Any] {
        let items: [[String: Any]] = selection.map { item in
            [
                "itemIdentifier": item.identifier.rawValue,
                "isFolder": item.isFolder,
                "isDownloaded": item.isDownloaded,
            ]
        }
        return ["fileproviderItems": items, "domainUserInfo": [String: Any]()]
    }
}
