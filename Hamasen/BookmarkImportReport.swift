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

extension CyberduckBookmark.ImportSummary {
    /// What to tell the user once the import has run.
    ///
    /// One paragraph per thing that happened, in the order the user cares
    /// about: what arrived, what it still needs, and what did not come
    /// across. Anything the reader could not use is stated rather than left
    /// out — an import that silently drops half a folder looks like one that
    /// worked.
    var report: String {
        [
            arrivalLine,
            credentialsLine,
            unresolvedPathsLine,
            duplicatesLine,
            unsupportedProtocolsLine,
            unusableFilesLine,
        ]
        .compactMap { $0 }
        .joined(separator: "\n\n")
    }

    private var arrivalLine: String {
        guard !servers.isEmpty else {
            return String(localized: "沒有可以匯入的書籤。")
        }
        let count = servers.count
        return String(localized: "已匯入 \(count) 台伺服器。")
    }

    private var credentialsLine: String? {
        guard !servers.isEmpty else { return nil }
        return String(
            localized: "Cyberduck 的密碼與金鑰存放在它自己的鑰匙圈項目中，無法一併匯入，請為每台伺服器重新設定登入資訊。"
        )
    }

    private var unresolvedPathsLine: String? {
        let count = servers.filter { $0.unresolvedRemotePath != nil }.count
        guard count > 0 else { return nil }
        return String(localized: "其中 \(count) 台的遠端路徑是相對於登入目錄的，已改為從根目錄掛載。")
    }

    private var duplicatesLine: String? {
        guard duplicateCount > 0 else { return nil }
        return String(localized: "\(duplicateCount) 個書籤已經在清單中，已略過。")
    }

    private var unsupportedProtocolsLine: String? {
        guard !unsupportedProtocols.isEmpty else { return nil }
        let names = ListFormatter.localizedString(byJoining: unsupportedProtocols)
        return String(localized: "以下協定尚未支援，使用它們的書籤已略過：\(names)。")
    }

    private var unusableFilesLine: String? {
        guard unusableCount > 0 else { return nil }
        return String(localized: "\(unusableCount) 個檔案不是可辨識的書籤。")
    }
}
