import Foundation
import Testing
@testable import HamasenCore

@Suite("CacheEvictionPlan")
struct CacheEvictionPlanTests {
    private static let serverID = UUID(uuidString: "D43D14AD-BDCD-4EED-9A5D-8E2B33127075")!
    private static let otherServerID = UUID(uuidString: "1E1AC5B4-9E5E-4C0E-9E43-8E4E2E7F0A11")!

    private static func item(
        _ name: String,
        _ megabytes: Int64,
        daysOld: Int,
        server: UUID = serverID
    ) -> CachedItem {
        CachedItem(
            identifier: name,
            serverID: server,
            byteCount: megabytes * 1_000_000,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000 - Double(daysOld) * 86_400)
        )
    }

    @Test("未設限的伺服器不動任何內容")
    func unlimitedKeepsEverything() {
        let items = [Self.item("a", 500, daysOld: 9), Self.item("b", 500, daysOld: 1)]
        let plan = CacheEvictionPlan.itemsToEvict(
            from: items, policies: [Self.serverID: .unlimited], limit: 100
        )
        #expect(plan.isEmpty)
    }

    @Test("純線上會清掉全部")
    func keepNothingEvictsEverything() {
        let items = [Self.item("a", 1, daysOld: 9), Self.item("b", 1, daysOld: 1)]
        let plan = CacheEvictionPlan.itemsToEvict(
            from: items, policies: [Self.serverID: .keepNothing], limit: 100
        )
        #expect(Set(plan) == ["a", "b"])
    }

    @Test("未超過上限時不動作")
    func withinAllowanceKeepsEverything() {
        let items = [Self.item("a", 400, daysOld: 9), Self.item("b", 400, daysOld: 1)]
        let plan = CacheEvictionPlan.itemsToEvict(
            from: items, policies: [Self.serverID: .keepUpTo(bytes: 1_000_000_000)], limit: 100
        )
        #expect(plan.isEmpty)
    }

    /// The point of a soft limit: drop only as much as it takes to get under
    /// it, and drop the stalest content rather than whatever comes first.
    @Test("超過上限時只丟到剛好低於上限，且從最舊的開始")
    func evictsStalestUntilWithinAllowance() {
        let items = [
            Self.item("newest", 400, daysOld: 1),
            Self.item("oldest", 400, daysOld: 30),
            Self.item("middle", 400, daysOld: 10),
        ]
        let plan = CacheEvictionPlan.itemsToEvict(
            from: items, policies: [Self.serverID: .keepUpTo(bytes: 1_000_000_000)], limit: 100
        )
        #expect(plan == ["oldest"])
    }

    @Test("沒有修改時間的項目視為最舊")
    func itemsWithoutADateGoFirst() {
        let undated = CachedItem(
            identifier: "undated", serverID: Self.serverID, byteCount: 400_000_000, modifiedAt: nil
        )
        let plan = CacheEvictionPlan.itemsToEvict(
            from: [undated, Self.item("dated", 400, daysOld: 30)],
            policies: [Self.serverID: .keepUpTo(bytes: 500_000_000)],
            limit: 100
        )
        #expect(plan.first == "undated")
    }

    @Test("只處理有政策的伺服器，其餘不受影響")
    func leavesUnmanagedServersAlone() {
        let items = [
            Self.item("managed", 900, daysOld: 1),
            Self.item("other", 900, daysOld: 1, server: Self.otherServerID),
        ]
        let plan = CacheEvictionPlan.itemsToEvict(
            from: items, policies: [Self.serverID: .keepUpTo(bytes: 1)], limit: 100
        )
        #expect(plan == ["managed"])
    }

    @Test("一次處理的數量有上限")
    func respectsTheLimit() {
        let items = (0..<10).map { Self.item("item-\($0)", 1, daysOld: $0) }
        let plan = CacheEvictionPlan.itemsToEvict(
            from: items, policies: [Self.serverID: .keepNothing], limit: 3
        )
        #expect(plan.count == 3)
    }
}
