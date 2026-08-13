import Foundation
import Testing
@testable import HamasenCore

@Suite("FinderDomain")
struct FinderDomainTests {
    private enum TestError: LocalizedError {
        case notReady

        var errorDescription: String? { "not ready" }
    }

    @Test("掛載位置尚未就緒時會重試，成功後停止")
    func retriesUntilLocationAppears() async throws {
        var attempts = 0
        var delays: [UInt64] = []
        let expected = URL(fileURLWithPath: "/tmp/Hamasen", isDirectory: true)

        let resolved = try await FinderDomain.resolveUserVisibleLocationWithRetry(
            maximumAttempts: 4,
            initialDelayNanoseconds: 10,
            maximumDelayNanoseconds: 25,
            resolve: {
                attempts += 1
                guard attempts == 3 else { throw TestError.notReady }
                return expected
            },
            sleep: { delays.append($0) }
        )

        #expect(resolved == expected)
        #expect(attempts == 3)
        #expect(delays == [10, 20])
    }

    @Test("重試次數與退避時間都有上限")
    func stopsAfterMaximumAttempts() async {
        var attempts = 0
        var delays: [UInt64] = []

        do {
            _ = try await FinderDomain.resolveUserVisibleLocationWithRetry(
                maximumAttempts: 4,
                initialDelayNanoseconds: 10,
                maximumDelayNanoseconds: 25,
                resolve: {
                    attempts += 1
                    throw TestError.notReady
                },
                sleep: { delays.append($0) }
            )
            Issue.record("預期取得掛載位置失敗")
        } catch let error as FinderDomainError {
            switch error {
            case .userVisibleLocationUnavailable(let recordedAttempts, let lastError):
                #expect(recordedAttempts == 4)
                #expect(lastError == "not ready")
            case .notRegistered:
                Issue.record("應回報已達重試上限")
            }
        } catch {
            Issue.record("非預期錯誤：\(error)")
        }

        #expect(attempts == 4)
        #expect(delays == [10, 20, 25])
    }

    @Test("取消時不再重試")
    func propagatesCancellationWithoutRetrying() async {
        var attempts = 0
        var delays: [UInt64] = []

        await #expect(throws: CancellationError.self) {
            _ = try await FinderDomain.resolveUserVisibleLocationWithRetry(
                maximumAttempts: 4,
                initialDelayNanoseconds: 10,
                maximumDelayNanoseconds: 25,
                resolve: {
                    attempts += 1
                    throw CancellationError()
                },
                sleep: { delays.append($0) }
            )
        }

        #expect(attempts == 1)
        #expect(delays.isEmpty)
    }

    @Test("卸載最後一個伺服器會清除已發布的 Finder 路徑")
    func clearsPublishedLocation() {
        let suiteName = "FinderDomainTests.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suiteName)!
        defer { store.removePersistentDomain(forName: suiteName) }

        store.set("/tmp/old-hamasen-mount", forKey: AppSettings.Keys.mountRootPath)
        FinderDomain.clearPublishedUserVisibleLocation(from: store)

        #expect(store.string(forKey: AppSettings.Keys.mountRootPath) == nil)
    }
}
