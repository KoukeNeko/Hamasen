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

import AppKit
import HamasenCore
import UniformTypeIdentifiers

/// Collects Cyberduck and Mountain Duck bookmark files through the standard
/// open panel, which is also what grants a sandboxed app access to them.
enum BookmarkImporter {
    /// Cyberduck keeps its bookmarks in its own container, which this app
    /// cannot read, so the user points at them instead. A folder may be
    /// chosen as well, which is how a whole bookmark collection arrives.
    private static let fileExtensions = ["duck", "cyberduckprofile"]

    /// Shows the open panel and reads what the user chose, or returns nil
    /// when they cancelled.
    ///
    /// A file that cannot be read is still returned, with no contents: the
    /// reader counts it among the ones that named no server, which is what
    /// it is to the user either way.
    @MainActor
    static func promptForBookmarks() -> [CyberduckBookmarkFile]? {
        let panel = NSOpenPanel()
        panel.message = String(localized: "選擇 Cyberduck 或 Mountain Duck 的書籤檔案或資料夾")
        panel.prompt = String(localized: "匯入")
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = fileExtensions.compactMap {
            UTType(filenameExtension: $0)
        }

        guard panel.runModal() == .OK else { return nil }
        return panel.urls.flatMap(bookmarkFiles(at:)).map(read(_:))
    }

    /// The bookmark files a chosen URL stands for: a folder contributes the
    /// bookmarks directly inside it, anything else only itself.
    private static func bookmarkFiles(at url: URL) -> [URL] {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            return [url]
        }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { fileExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func read(_ url: URL) -> CyberduckBookmarkFile {
        CyberduckBookmarkFile(
            name: url.lastPathComponent,
            contents: (try? Data(contentsOf: url)) ?? Data()
        )
    }
}
