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

    private static let serverRoot = ItemIdentifierMapper.identifier(for: .serverRoot(serverID))
    private static let otherServerRoot = ItemIdentifierMapper.identifier(for: .serverRoot(otherServerID))
    private static let innerFile = ItemIdentifierMapper.identifier(
        for: .item(serverID: serverID, path: "/docs/report.txt")
    )
    private static let innerFolder = ItemIdentifierMapper.identifier(
        for: .item(serverID: serverID, path: "/docs")
    )
    /// The system normalises this spelling to the server root; the rule has
    /// to accept it as well.
    private static let serverRootWithSlash = ItemIdentifierMapper.identifier(
        for: .item(serverID: serverID, path: RemotePath.root)
    )

    /// Every selection the rules are expected to tell apart, with the
    /// entries each one must show.
    private static let expectations: [(selection: [NSFileProviderItemIdentifier], visible: Set<FinderAction>, label: String)] = [
        ([innerFile], [.copyRemotePath, .refresh], "single file"),
        ([innerFolder], [.copyRemotePath, .refresh], "single folder"),
        ([serverRoot], [.copyRemotePath, .refresh, .unmountServer], "single server folder"),
        ([serverRootWithSlash], [.copyRemotePath, .refresh, .unmountServer], "server folder as srv:<uuid>:/"),
        ([innerFile, innerFolder], [.refresh], "two items"),
        ([serverRoot, otherServerRoot], [.refresh], "two server folders"),
        ([.rootContainer], [.refresh], "the Hamasen root"),
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
    /// Only the fields the shipped rules read are modelled.
    private static func predicateContext(for selection: [NSFileProviderItemIdentifier]) -> [String: Any] {
        let items: [[String: Any]] = selection.map { identifier in
            ["itemIdentifier": identifier.rawValue]
        }
        return ["fileproviderItems": items, "domainUserInfo": [String: Any]()]
    }
}
