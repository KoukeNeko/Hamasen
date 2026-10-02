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

/// Names the copy that keeps a local edit when the server's version of the
/// same file moved on underneath it.
enum ConflictCopyName {
    /// "report.pdf" becomes "report (conflict 2026-09-30 141500).pdf". Not
    /// localized: it is a file name, and it has to stay recognizable and
    /// sortable wherever the file is later opened. `attempt` distinguishes
    /// copies made within the same second.
    static func make(for name: String, at date: Date, attempt: Int = 0) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        let suffix = attempt == 0 ? "" : " \(attempt + 1)"
        let label = " (conflict \(formatter.string(from: date))\(suffix))"

        let base = (name as NSString).deletingPathExtension
        let fileExtension = (name as NSString).pathExtension
        return fileExtension.isEmpty ? base + label : "\(base)\(label).\(fileExtension)"
    }
}
