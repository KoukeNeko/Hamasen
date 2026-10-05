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
import SwiftUI
import UniformTypeIdentifiers

/// The connection's icon in its page header, which is also how its Finder
/// folder's look is changed: clicking it offers the color, symbol, emoji or
/// picture Finder's own Customize Folder offers for a local folder.
struct FolderAppearanceButton: View {
    @Binding var appearance: FinderAppearance
    @Binding var pendingImage: NSImage?
    let serverID: UUID
    let kind: ServiceKind
    var size: CGFloat = 52

    @State private var isChoosing = false
    @State private var isImporting = false
    @State private var importFailure: String?

    /// Symbols that read as places a server folder leads to.
    private static let symbols = [
        "server.rack", "externaldrive.fill", "internaldrive.fill", "cloud.fill",
        "network", "globe", "terminal.fill", "desktopcomputer",
        "house.fill", "building.2.fill", "briefcase.fill", "folder.fill",
        "doc.fill", "photo.fill", "film.fill", "music.note",
        "gamecontroller.fill", "hammer.fill", "wrench.and.screwdriver.fill", "lock.fill",
        "star.fill", "heart.fill", "flag.fill", "bolt.fill",
    ]
    private static let symbolsPerRow = 8

    private var icon: FinderAppearance.Icon? {
        get { appearance.icon }
        nonmutating set { appearance.icon = newValue }
    }

    var body: some View {
        Button {
            isChoosing = true
        } label: {
            tile
                .overlay(alignment: .bottomTrailing) {
                    if let color = appearance.color {
                        Circle()
                            .fill(color.swatch)
                            .strokeBorder(.background, lineWidth: 2)
                            .frame(width: size * 0.3, height: size * 0.3)
                            .offset(x: 3, y: 3)
                    }
                }
        }
        .buttonStyle(.plain)
        // A fixed frame, so every choice takes the same place in the header.
        .frame(width: size, height: size)
        .accessibilityLabel(Text("圖示"))
        // On the button, not inside the popover: the popover closes as the
        // panel opens, and whatever it hosted goes with it.
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.image]) { result in
            useImage(from: result)
        }
        .alert(
            "無法讀取這張圖片",
            isPresented: Binding(get: { importFailure != nil }, set: { if !$0 { importFailure = nil } })
        ) {
            Button("確定", role: .cancel) {}
        } message: {
            Text(importFailure ?? "")
        }
        .popover(isPresented: $isChoosing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                colorRow
                Divider()
                Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                    ForEach(0..<Self.symbols.count / Self.symbolsPerRow, id: \.self) { row in
                        GridRow {
                            ForEach(Self.symbols[row * Self.symbolsPerRow..<(row + 1) * Self.symbolsPerRow], id: \.self) { name in
                                Button {
                                    choose(.symbol(name))
                                } label: {
                                    Image(systemName: name)
                                        .frame(width: 32, height: 32)
                                        .background(
                                            icon == .symbol(name) ? Color.accentColor.opacity(0.25) : .clear,
                                            in: .rect(cornerRadius: 6))
                                        .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                                .help(name)
                            }
                        }
                    }
                }
                Divider()
                HStack {
                    TextField("Emoji", text: emojiBinding)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Spacer()
                    Button("選擇圖片…") {
                        isChoosing = false
                        isImporting = true
                    }
                    Button("清除") { choose(nil) }
                        .disabled(icon == nil)
                }
            }
            .padding(14)
        }
    }

    /// What Finder will show, drawn the way the app draws connections.
    @ViewBuilder
    private var tile: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
        let tint = appearance.color?.swatch ?? kind.tint
        switch icon {
        case .symbol(let name):
            SymbolTile(symbol: name, tint: tint, size: size)
        case .emoji(let character):
            shape.fill(tint.gradient)
                .frame(width: size, height: size)
                .overlay { Text(verbatim: character).font(.system(size: size * 0.55)) }
        case .image:
            if let picture = pendingImage ?? CustomFolderIcon.storedImage(for: serverID) {
                // Filled and cropped to the tile, as a photo would be in a
                // folder's icon; fitted, a tall picture became a sliver.
                Color.clear
                    .frame(width: size, height: size)
                    .overlay { Image(nsImage: picture).resizable().scaledToFill() }
                    .clipShape(shape)
            } else {
                ServiceIcon(kind: kind, size: size)
            }
        case nil:
            ServiceIcon(kind: kind, size: size)
        }
    }

    private var colorRow: some View {
        HStack(spacing: 8) {
            colorButton(nil)
            ForEach(FinderAppearance.TagColor.allCases, id: \.self) { colorButton($0) }
        }
    }

    private func colorButton(_ color: FinderAppearance.TagColor?) -> some View {
        Button {
            appearance.color = color
        } label: {
            ZStack {
                if let color {
                    Circle().fill(color.swatch)
                } else {
                    Image(systemName: "circle.slash").font(.title2).foregroundStyle(.secondary)
                }
                if appearance.color == color {
                    Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                }
            }
            .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .help(color.map { Text($0.title) } ?? Text("未設定"))
        .accessibilityLabel(color.map { Text($0.title) } ?? Text("未設定"))
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
                pendingImage = nil
            }
        )
    }

    /// Leaves the popover open, as the color choices and Finder's own
    /// Customize Folder do, so the result can be seen and changed again.
    private func choose(_ newIcon: FinderAppearance.Icon?) {
        icon = newIcon
        pendingImage = nil
    }

    private func useImage(from result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let hasScopedAccess = url.startAccessingSecurityScopedResource()
            defer { if hasScopedAccess { url.stopAccessingSecurityScopedResource() } }
            guard let picture = NSImage(contentsOf: url), picture.isValid else {
                throw CustomFolderIcon.Failure.unreadableImage
            }
            icon = .image
            pendingImage = picture
        } catch {
            importFailure = error.localizedDescription
        }
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
