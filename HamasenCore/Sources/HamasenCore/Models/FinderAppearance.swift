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

/// How a server's folder looks in Finder. Every part is optional, and an
/// unset part leaves Finder's own default. The folder's name is the
/// connection's own; there is no second one for Finder.
///
/// The color and the symbol are what Finder's Customize Folder writes on a
/// local folder: a color tag, and a JSON object in `com.apple.icon.folder#S`.
/// The provider hands both over as the folder item's tags and extended
/// attributes, so Finder draws them the same way.
public struct FinderAppearance: Codable, Hashable, Sendable {
    public var color: TagColor?
    public var icon: Icon?

    public init(color: TagColor? = nil, icon: Icon? = nil) {
        self.color = color
        self.icon = icon
    }

    /// Finder's seven tag colors, numbered as Finder numbers its labels.
    public enum TagColor: Int, Codable, CaseIterable, Sendable {
        case gray = 1, green, purple, blue, yellow, red, orange

        /// The tag's name as Finder writes it, in English on every system;
        /// Finder shows its own localized name for these seven.
        var tagName: String {
            switch self {
            case .gray: "Gray"
            case .green: "Green"
            case .purple: "Purple"
            case .blue: "Blue"
            case .yellow: "Yellow"
            case .red: "Red"
            case .orange: "Orange"
            }
        }
    }

    /// Stored as `{"symbol": name}`, `{"emoji": character}` or
    /// `{"image": true}`.
    public enum Icon: Codable, Hashable, Sendable {
        /// An SF Symbol name.
        case symbol(String)
        case emoji(String)
        /// A picture of the user's own. Finder's Customize Folder has no
        /// place for one, so it goes on the folder the classic way, as the
        /// hidden `Icon\r` file the app writes on this Mac; the picture
        /// itself stays with the app and is not part of the configuration.
        case image

        private enum CodingKeys: String, CodingKey {
            case symbol, emoji, image
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let name = try container.decodeIfPresent(String.self, forKey: .symbol) {
                self = .symbol(name)
            } else if let character = try container.decodeIfPresent(String.self, forKey: .emoji) {
                self = .emoji(character)
            } else if try container.decodeIfPresent(Bool.self, forKey: .image) == true {
                self = .image
            } else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: container.codingPath, debugDescription: "No symbol, emoji or image"))
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .symbol(let name): try container.encode(name, forKey: .symbol)
            case .emoji(let character): try container.encode(character, forKey: .emoji)
            case .image: try container.encode(true, forKey: .image)
            }
        }
    }

    /// The extended attribute Finder reads a folder's symbol or emoji from.
    public static let iconAttributeName = "com.apple.icon.folder#S"

    /// The tags blob `NSFileProviderItem.tagData` takes: the same binary
    /// property list Finder keeps in `com.apple.metadata:_kMDItemUserTags`.
    public var tagData: Data? {
        guard let color else { return nil }
        return try? PropertyListSerialization.data(
            fromPropertyList: ["\(color.tagName)\n\(color.rawValue)"], format: .binary, options: 0)
    }

    /// The value of `iconAttributeName`, or nil for Finder's plain folder.
    public var iconAttribute: Data? {
        let entry: [String: String]
        switch icon {
        case .symbol(let name): entry = ["sym": name]
        case .emoji(let character): entry = ["emoji": character]
        case .image, nil: return nil
        }
        return try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
    }

    /// Part of the folder's item version: empty for the default, so folders
    /// that were never customized keep the version they had.
    var versionToken: String {
        guard self != FinderAppearance() else { return "" }
        let iconToken = switch icon {
        case .symbol(let name): "sym:\(name)"
        case .emoji(let character): "emoji:\(character)"
        case .image: "image"
        case nil: ""
        }
        return "|look:\(color?.rawValue ?? 0)|\(iconToken)"
    }
}
