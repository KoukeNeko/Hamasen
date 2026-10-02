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
import HamasenCore
import UserNotifications

/// The notifications Hamasen sends, and the switches that silence each kind.
///
/// Problems that stop files moving — a connection lost, a sign-in expired —
/// and conflicts are on by default: each is something the person would
/// otherwise discover by finding a file out of date. Changes on the server
/// are off by default, since they are the ordinary business of a shared
/// folder and show up in Finder by themselves.
@MainActor
enum AppNotifier {
    enum Kind: String, CaseIterable {
        case connectionProblems
        case conflicts
        case remoteChanges
        case updates

        var defaultsKey: String { "notify.\(rawValue)" }

        var isOnByDefault: Bool { self != .remoteChanges }

        var isEnabled: Bool {
            UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? isOnByDefault
        }
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Asks once; macOS remembers the answer and later calls return it.
    @discardableResult
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func connectionLost(_ server: ServerConfig, message: String?) {
        post(.connectionProblems, id: "connection-\(server.id)",
             title: String(localized: "無法連線到「\(server.name)」"),
             body: message ?? String(localized: "網路恢復後會自動重新連線。"))
    }

    static func signInRequired(_ server: ServerConfig) {
        post(.connectionProblems, id: "connection-\(server.id)",
             title: String(localized: "「\(server.name)」需要重新登入"),
             body: String(localized: "更新登入資訊後，同步會繼續。"))
    }

    static func conflict(_ conflict: ConflictRecord, serverName: String) {
        post(.conflicts, id: "conflict-\(conflict.id)",
             title: String(localized: "「\(conflict.fileName)」兩邊都有修改"),
             body: String(localized: "這台 Mac 的版本另存為「\(conflict.copyName)」，在「\(serverName)」的同一個資料夾。"))
    }

    static func remoteChanges(_ summary: RemoteChangeSummary) {
        post(.remoteChanges, id: UUID().uuidString, title: summary.title, body: summary.message)
    }

    static func updateAvailable(version: String) {
        let name = AppInfo.displayName
        post(.updates, id: "update-\(version)",
             title: String(localized: "\(name) \(version) 已推出"),
             body: String(localized: "到「設定 › 軟體更新」下載。"))
    }

    /// Delivered now; an identifier repeated replaces the earlier banner
    /// rather than stacking another one beside it.
    private static func post(_ kind: Kind, id: String, title: String, body: String) {
        guard kind.isEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        Task {
            guard await authorizationStatus() == .authorized else { return }
            try? await UNUserNotificationCenter.current().add(request)
        }
    }
}

/// Shows Hamasen's banners even while the app is in front, where macOS
/// would otherwise drop them.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
