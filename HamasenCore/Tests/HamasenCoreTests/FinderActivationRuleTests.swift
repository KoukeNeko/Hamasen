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
        var isPinned = false

        static func folder(_ entity: ProviderEntity) -> IndexedItem {
            IndexedItem(identifier: ItemIdentifierMapper.identifier(for: entity), isFolder: true, isDownloaded: true)
        }

        static func file(
            _ entity: ProviderEntity, isDownloaded: Bool, isPinned: Bool = false
        ) -> IndexedItem {
            IndexedItem(
                identifier: ItemIdentifierMapper.identifier(for: entity),
                isFolder: false,
                isDownloaded: isDownloaded,
                isPinned: isPinned
            )
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
    private static let pinnedFile = IndexedItem.file(
        .item(serverID: serverID, path: "/docs/kept.md"), isDownloaded: true, isPinned: true
    )
    /// The system normalises this spelling to the server root; the rule has
    /// to accept it as well.
    private static let serverRootWithSlash = IndexedItem.folder(.item(serverID: serverID, path: RemotePath.root))

    /// Every selection the rules are expected to tell apart, with the
    /// entries each one must show.
    private static let expectations: [(selection: [IndexedItem], visible: Set<FinderAction>, label: String)] = [
        ([datalessFile], [.copyRemotePath, .copyLocalPath, .refresh, .keepOnMac], "single dataless file"),
        ([downloadedFile], [.copyRemotePath, .copyLocalPath, .refresh, .freeLocalSpace, .keepOnMac], "single downloaded file"),
        // The pair is exclusive: a kept file offers only the way back.
        ([pinnedFile], [.copyRemotePath, .copyLocalPath, .refresh, .freeLocalSpace, .stopKeepingOnMac], "a kept file"),
        ([datalessFile, pinnedFile], [.refresh, .freeLocalSpace], "a kept file mixed with an unkept one"),
        ([innerFolder], [.copyRemotePath, .copyLocalPath, .refresh, .freeLocalSpace], "single folder"),
        ([serverRoot], [.copyRemotePath, .copyLocalPath, .refresh, .unmountServer, .freeLocalSpace], "single server folder"),
        ([serverRootWithSlash], [.copyRemotePath, .copyLocalPath, .refresh, .unmountServer, .freeLocalSpace], "server folder as srv:<uuid>:/"),
        // Several unkept files can be kept in one go.
        ([datalessFile, downloadedFile], [.refresh, .freeLocalSpace, .keepOnMac], "two files, one downloaded"),
        ([datalessFile, innerFolder], [.refresh, .freeLocalSpace], "a file and a folder"),
        ([serverRoot, otherServerRoot], [.refresh, .freeLocalSpace], "two server folders"),
        // The root has no address on a server, but it does have one on this Mac.
        ([hamasenRoot], [.copyLocalPath, .refresh, .freeLocalSpace], "the Hamasen root"),
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

    /// App Store validation rejects a File Provider extension that does not
    /// name its document group, and a name that no entitlement grants would
    /// leave the extension unable to reach the shared state it runs on. Both
    /// are invisible until an upload is rejected or a mount comes up empty.
    @Test("擴充功能宣告的文件群組存在，且與權限和程式碼一致")
    func declaresTheDocumentGroupItsEntitlementsGrant() throws {
        let declared = try #require(
            Self.extensionInfo()["NSExtensionFileProviderDocumentGroup"] as? String
        )
        let granted = try #require(
            Self.configuration("HamasenFileProvider.entitlements")[
                "com.apple.security.application-groups"
            ] as? [String]
        )

        #expect(declared == SharedConstants.appGroupIdentifier)
        #expect(granted.contains(declared))
    }

    // MARK: - Fixtures

    private struct DeclaredAction {
        let identifier: String
        let name: String
        let rule: String
    }

    /// The repository root, so a test reads what ships rather than a copy.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // HamasenCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // HamasenCore
            .deletingLastPathComponent()  // repository root
    }

    private static func configuration(_ name: String) throws -> [String: Any] {
        let url = repositoryRoot.appendingPathComponent("Config/\(name)")
        let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: url), format: nil
        )
        return try #require(plist as? [String: Any])
    }

    private static func extensionInfo() throws -> [String: Any] {
        try #require(
            configuration("HamasenFileProviderInfo.plist")["NSExtension"] as? [String: Any]
        )
    }

    /// Reads the extension's Info.plist from the repository, so the test
    /// runs against what ships and not a copy of it.
    private static func declaredActions() throws -> [DeclaredAction] {
        let extensionInfo = try extensionInfo()
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
                "userInfo": ["isPinned": item.isPinned],
            ]
        }
        return ["fileproviderItems": items, "domainUserInfo": [String: Any]()]
    }
}
