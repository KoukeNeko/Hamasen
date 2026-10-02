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
import StoreKit

/// What the bundle says about the app, read in one place.
nonisolated enum AppInfo {
    /// Localized in the Info.plist catalog (哈瑪星 / Hamasen), so it is never
    /// written out again in code.
    static var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Hamasen"
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// Whether this copy came from the App Store or TestFlight, which update
    /// it themselves; such a copy must not offer an update of its own. A
    /// build from anywhere else has no App Store transaction to verify.
    static func isFromAppStore() async -> Bool {
        guard case .verified(let transaction)? = try? await AppTransaction.shared else { return false }
        return transaction.environment == .production || transaction.environment == .sandbox
    }
}
