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

import HamasenCore
import SwiftUI

/// What one connection is doing, as every view that lists connections
/// shows it.
enum ConnectionStatus: Equatable {
    /// Not in Finder.
    case notMounted
    case paused
    /// In Finder, with nothing known to be wrong.
    case connected
    /// In Finder and moving files right now.
    case syncing
    /// The last attempt to reach it failed.
    case unreachable(String?)
    /// It refused the stored password, key or sign-in.
    case signInRequired(String?)

    var title: LocalizedStringKey {
        switch self {
        case .notMounted: return "未掛載"
        case .paused: return "已暫停"
        case .connected: return "已連線"
        case .syncing: return "同步中"
        case .unreachable: return "無法連線"
        case .signInRequired: return "需要重新登入"
        }
    }

    var symbol: String {
        switch self {
        case .notMounted: return "circle.dashed"
        case .paused: return "pause.circle.fill"
        case .connected: return "checkmark.circle.fill"
        case .syncing: return "arrow.triangle.2.circlepath.circle.fill"
        case .unreachable: return "exclamationmark.triangle.fill"
        case .signInRequired: return "person.crop.circle.badge.exclamationmark.fill"
        }
    }

    var tint: Color {
        switch self {
        case .notMounted: return .secondary
        case .paused: return .gray
        case .connected: return .green
        case .syncing: return .blue
        case .unreachable, .signInRequired: return .orange
        }
    }

    /// Something the person has to act on.
    var needsAttention: Bool {
        switch self {
        case .unreachable, .signInRequired: return true
        case .notMounted, .paused, .connected, .syncing: return false
        }
    }

    /// The explanation behind a problem, for a tooltip or a detail line.
    var detail: String? {
        switch self {
        case .unreachable(let message), .signInRequired(let message): return message
        case .notMounted, .paused, .connected, .syncing: return nil
        }
    }

    /// The server's own words for a problem or, when it gave none, what the
    /// notifications say about it.
    var explanation: String? {
        switch self {
        case .unreachable(let message): return message ?? String(localized: "網路恢復後會自動重新連線。")
        case .signInRequired(let message): return message ?? String(localized: "更新登入資訊後，同步會繼續。")
        case .notMounted, .paused, .connected, .syncing: return nil
        }
    }

    /// Where a state sorts when connections are counted by state, problems
    /// first — the precedence `OverallStatus.combining` gives them. Problems
    /// with different messages are still one state.
    var rank: Int {
        switch self {
        case .signInRequired: return 0
        case .unreachable: return 1
        case .syncing: return 2
        case .connected: return 3
        case .paused: return 4
        case .notMounted: return 5
        }
    }
}

/// What every connection together is doing: the menu bar's icon and
/// headline.
enum OverallStatus: Equatable {
    case noConnections
    case normal
    case syncing
    case needsAttention(count: Int)
    case paused

    var symbol: String {
        switch self {
        case .noConnections, .normal: return "externaldrive.connected.to.line.below"
        case .syncing: return "arrow.triangle.2.circlepath"
        case .needsAttention: return "exclamationmark.triangle"
        case .paused: return "pause.circle"
        }
    }

    var headlineSymbol: String {
        switch self {
        case .noConnections: return "externaldrive.badge.plus"
        case .normal: return "checkmark.circle.fill"
        case .syncing: return "arrow.triangle.2.circlepath.circle.fill"
        case .needsAttention: return "exclamationmark.triangle.fill"
        case .paused: return "pause.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .noConnections: return .secondary
        case .normal: return .green
        case .syncing: return .blue
        case .needsAttention: return .orange
        case .paused: return .gray
        }
    }

    var title: String {
        switch self {
        case .noConnections: return String(localized: "沒有連線")
        case .normal: return String(localized: "一切正常")
        case .syncing: return String(localized: "同步中")
        case .needsAttention(let count): return String(localized: "\(count) 組連線需要處理")
        case .paused: return String(localized: "已暫停")
        }
    }

    /// Combines the connections' states: a problem outranks activity, which
    /// outranks rest, and only a set that is entirely paused reads as paused.
    static func combining(_ statuses: [ConnectionStatus]) -> OverallStatus {
        let active = statuses.filter { $0 != .notMounted }
        guard !active.isEmpty else { return statuses.isEmpty ? .noConnections : .normal }
        let problems = active.filter(\.needsAttention).count
        if problems > 0 { return .needsAttention(count: problems) }
        if active.contains(.syncing) { return .syncing }
        if active.allSatisfy({ $0 == .paused }) { return .paused }
        return .normal
    }
}

/// A status as a symbol in its colour, for rows that have no room for words.
struct ConnectionStatusIcon: View {
    let status: ConnectionStatus

    var body: some View {
        Image(systemName: status.symbol)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(status.tint)
            .help(Text(status.title))
            .accessibilityLabel(Text(status.title))
    }
}

/// A status as a symbol and its name.
struct ConnectionStatusLabel: View {
    let status: ConnectionStatus

    var body: some View {
        Label {
            Text(status.title)
        } icon: {
            Image(systemName: status.symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(status.tint)
        }
        .help(status.detail ?? "")
    }
}

/// A status in a tinted capsule, beside a connection's name.
struct ConnectionStatusBadge: View {
    let status: ConnectionStatus

    var body: some View {
        Label {
            Text(status.title)
        } icon: {
            Image(systemName: status.symbol)
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(status.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(status.tint.opacity(0.14), in: Capsule())
        .help(status.detail ?? "")
    }
}
