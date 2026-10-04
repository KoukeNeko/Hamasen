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

/// How the connection's folder looks in Finder: the same name, color and
/// symbol Finder's own Customize Folder offers for a local folder.
struct FinderAppearanceSection: View {
    @Binding var draft: ConnectionDraft

    var body: some View {
        Section("Finder 資料夾") {
            TextField("名稱", text: nameBinding, prompt: Text(draft.makeConfig()?.name ?? draft.suggestedName))
            Picker("顏色", selection: $draft.finderAppearance.color) {
                Text("未設定").tag(FinderAppearance.TagColor?.none)
                ForEach(FinderAppearance.TagColor.allCases, id: \.self) { color in
                    Label {
                        Text(color.title)
                    } icon: {
                        Image(systemName: "circle.fill").foregroundStyle(color.swatch)
                    }
                    .tag(FinderAppearance.TagColor?.some(color))
                }
            }
            LabeledContent("圖示") {
                FolderIconPicker(icon: $draft.finderAppearance.icon)
            }
        }
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { draft.finderAppearance.name ?? "" },
            set: { draft.finderAppearance.name = $0 }
        )
    }
}

/// A button showing the chosen symbol or emoji, opening a grid to choose.
private struct FolderIconPicker: View {
    @Binding var icon: FinderAppearance.Icon?
    @State private var isChoosing = false

    /// Symbols that read as places a server folder leads to.
    private static let symbols = [
        "server.rack", "externaldrive.fill", "internaldrive.fill", "cloud.fill",
        "network", "globe", "terminal.fill", "desktopcomputer",
        "house.fill", "building.2.fill", "briefcase.fill", "folder.fill",
        "doc.fill", "photo.fill", "film.fill", "music.note",
        "gamecontroller.fill", "hammer.fill", "wrench.and.screwdriver.fill", "lock.fill",
        "star.fill", "heart.fill", "flag.fill", "bolt.fill",
    ]

    var body: some View {
        Button {
            isChoosing = true
        } label: {
            switch icon {
            case .symbol(let name): Image(systemName: name)
            case .emoji(let character): Text(verbatim: character)
            case nil: Text("未設定")
            }
        }
        .popover(isPresented: $isChoosing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 6), count: 8), spacing: 6) {
                    ForEach(Self.symbols, id: \.self) { name in
                        Button {
                            icon = .symbol(name)
                            isChoosing = false
                        } label: {
                            Image(systemName: name)
                                .frame(width: 32, height: 32)
                                .background(
                                    icon == .symbol(name) ? Color.accentColor.opacity(0.25) : .clear,
                                    in: .rect(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .help(name)
                    }
                }
                Divider()
                HStack {
                    TextField("Emoji", text: emojiBinding)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Spacer()
                    Button("清除") {
                        icon = nil
                        isChoosing = false
                    }
                    .disabled(icon == nil)
                }
            }
            .padding(14)
        }
    }

    private var emojiBinding: Binding<String> {
        Binding(
            get: {
                if case .emoji(let character) = icon { return character }
                return ""
            },
            set: { text in
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                icon = trimmed.isEmpty ? nil : .emoji(trimmed)
            }
        )
    }
}

extension FinderAppearance.TagColor {
    var title: LocalizedStringResource {
        switch self {
        case .gray: "灰色"
        case .green: "綠色"
        case .purple: "紫色"
        case .blue: "藍色"
        case .yellow: "黃色"
        case .red: "紅色"
        case .orange: "橙色"
        }
    }

    var swatch: Color {
        switch self {
        case .gray: .gray
        case .green: .green
        case .purple: .purple
        case .blue: .blue
        case .yellow: .yellow
        case .red: .red
        case .orange: .orange
        }
    }
}
