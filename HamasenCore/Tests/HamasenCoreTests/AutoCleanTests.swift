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

@Suite("Automatic cleaning")
struct AutoCleanTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let server = UUID()

    private static func item(
        _ name: String, megabytes: Int64, usedDaysAgo: Double?, modifiedDaysAgo: Double = 400
    ) -> CachedItem {
        CachedItem(
            identifier: name, serverID: server, byteCount: megabytes * 1_000_000,
            modifiedAt: now.addingTimeInterval(-modifiedDaysAgo * 86_400),
            lastUsedAt: usedDaysAgo.map { now.addingTimeInterval(-$0 * 86_400) })
    }

    @Test("超過天數沒用的移除，最近用過的保留")
    func dropsWhatWasNotUsedLately() {
        let items = [
            Self.item("old", megabytes: 1, usedDaysAgo: 10),
            Self.item("recent", megabytes: 1, usedDaysAgo: 1),
        ]
        let plan = CacheEvictionPlan.itemsToClean(
            from: items, policy: AutoCleanPolicy(unusedDays: 7, totalLimitBytes: nil), now: Self.now, limit: 100)
        #expect(plan == ["old"])
    }

    @Test("沒有使用紀錄的項目不會因為伺服器修改日期老舊而被移除")
    func keepsItemsWithoutAUseRecord() {
        let items = [Self.item("unknown", megabytes: 1, usedDaysAgo: nil, modifiedDaysAgo: 900)]
        let plan = CacheEvictionPlan.itemsToClean(
            from: items, policy: AutoCleanPolicy(unusedDays: 1, totalLimitBytes: nil), now: Self.now, limit: 100)
        #expect(plan.isEmpty)
    }

    @Test("總量超過上限時從最久沒用的開始移除，保留的檔案不計")
    func enforcesTheCeilingStalestFirst() {
        let items = [
            Self.item("a", megabytes: 400, usedDaysAgo: 3),
            Self.item("b", megabytes: 400, usedDaysAgo: 2),
            Self.item("c", megabytes: 400, usedDaysAgo: 1),
            Self.item("pinned", megabytes: 400, usedDaysAgo: 5),
        ]
        let plan = CacheEvictionPlan.itemsToClean(
            from: items, policy: AutoCleanPolicy(unusedDays: 30, totalLimitBytes: 1_000_000_000),
            pinned: ["pinned"], now: Self.now, limit: 100)
        // 1.6 GB held: dropping a and b brings it to 0.8 GB.
        #expect(plan == ["a", "b"])
    }

    @Test("已因閒置移除的不重複計入上限")
    func doesNotCountWhatAgeAlreadyDropped() {
        let items = [
            Self.item("stale", megabytes: 900, usedDaysAgo: 20),
            Self.item("fresh", megabytes: 500, usedDaysAgo: 1),
        ]
        let plan = CacheEvictionPlan.itemsToClean(
            from: items, policy: AutoCleanPolicy(unusedDays: 7, totalLimitBytes: 1_000_000_000),
            now: Self.now, limit: 100)
        #expect(plan == ["stale"])
    }

    @Test("設定值超出選項時回到預設")
    func readsSettings() throws {
        let store = try #require(UserDefaults(suiteName: "auto-clean-\(UUID().uuidString)"))
        #expect(AppSettings.autoCleanPolicy(from: store)
            == AutoCleanPolicy(unusedDays: 7, totalLimitBytes: 10_000_000_000))
        store.set(5, forKey: AppSettings.Keys.autoCleanUnusedDays)
        store.set(Int64(0), forKey: AppSettings.Keys.autoCleanTotalLimitBytes)
        #expect(AppSettings.autoCleanPolicy(from: store) == AutoCleanPolicy(unusedDays: 7, totalLimitBytes: nil))
        store.set(false, forKey: AppSettings.Keys.autoCleanEnabled)
        #expect(AppSettings.autoCleanPolicy(from: store) == nil)
    }
}

@Suite("ItemUsageStore")
struct ItemUsageStoreTests {
    private static func store() -> ItemUsageStore {
        ItemUsageStore(fileURL: FileManager.default.temporaryDirectory.appending(path: "usage-\(UUID().uuidString).json"))
    }

    @Test("最近一次使用取開啟、下載與首次看到中最晚的")
    func takesTheLatestSignal() throws {
        let store = Self.store()
        let opened = Date(timeIntervalSince1970: 1_000)
        let downloaded = Date(timeIntervalSince1970: 2_000)
        try store.recordUse(of: "a", at: opened)
        try store.recordDownload(of: "a", at: downloaded)
        #expect(try store.load()["a"]?.latest == downloaded)
    }

    @Test("對帳時記下新出現的項目並忘掉已不在本機的")
    func reconciles() throws {
        let store = Self.store()
        try store.recordDownload(of: "gone", at: Date())
        let seen = Date(timeIntervalSince1970: 5_000)
        let usage = try store.reconcile(present: ["new"], at: seen)
        #expect(usage["gone"] == nil)
        #expect(usage["new"]?.firstSeen == seen)
        // Seeing it again does not reset when it was first seen.
        let again = try store.reconcile(present: ["new"], at: seen.addingTimeInterval(100))
        #expect(again["new"]?.firstSeen == seen)
    }
}
