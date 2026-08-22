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

    /// The sweep cannot fix this one: everything unpinned is already gone and
    /// the server is still over, because the user asked for that content.
    @Test("光是釘選就超額時會被指出來")
    func reportsServersHeldOverByPins() {
        let items = [Self.item("kept", 900, daysOld: 1), Self.item("other", 100, daysOld: 2)]
        let overages = CacheEvictionPlan.serversHeldOverAllowanceByPins(
            items: items,
            policies: [Self.serverID: .keepUpTo(bytes: 500_000_000)],
            pinned: ["kept"]
        )
        #expect(overages[Self.serverID] == PinnedOverage(pinnedBytes: 900_000_000, allowanceBytes: 500_000_000))
    }

    @Test("釘選仍在額度內時不算超額")
    func reportsNothingWhenPinsFitTheAllowance() {
        let items = [Self.item("kept", 100, daysOld: 1), Self.item("other", 900, daysOld: 2)]
        let overages = CacheEvictionPlan.serversHeldOverAllowanceByPins(
            items: items,
            policies: [Self.serverID: .keepUpTo(bytes: 500_000_000)],
            pinned: ["kept"]
        )
        #expect(overages.isEmpty)
    }

    @Test("沒有上限的伺服器不會被指出來")
    func reportsNothingWithoutAnAllowance() {
        let overages = CacheEvictionPlan.serversHeldOverAllowanceByPins(
            items: [Self.item("kept", 900, daysOld: 1)],
            policies: [Self.serverID: .unlimited],
            pinned: ["kept"]
        )
        #expect(overages.isEmpty)
    }

    @Test("用量按伺服器分開，並區分保留與可清除")
    func reportsUsagePerServerSplitByPin() {
        let items = [
            Self.item("kept", 300, daysOld: 1),
            Self.item("cached", 200, daysOld: 2),
            Self.item("elsewhere", 50, daysOld: 3, server: Self.otherServerID),
        ]
        let usage = CacheEvictionPlan.usage(of: items, pinned: ["kept"])

        #expect(usage[Self.serverID] == CacheUsage(pinnedBytes: 300_000_000, evictableBytes: 200_000_000))
        #expect(usage[Self.serverID]?.totalBytes == 500_000_000)
        #expect(usage[Self.otherServerID] == CacheUsage(pinnedBytes: 0, evictableBytes: 50_000_000))
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
