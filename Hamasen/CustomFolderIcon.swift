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
import FileProvider
import HamasenCore
import ImageIO

/// A connection's own picture for its Finder folder.
///
/// Finder keeps a folder's custom icon in a hidden `Icon\r` file inside it,
/// which the extension keeps off the server, so it lives only in this Mac's
/// copy of the folder and goes with it: resetting the Finder location or
/// unmounting removes it. The picture is therefore also kept here, and put
/// back from here whenever the folder turns up without it.
enum CustomFolderIcon {
    enum Failure: LocalizedError {
        case unreadableImage
        case notApplied

        var errorDescription: String? {
            switch self {
            case .unreadableImage: String(localized: "無法讀取這張圖片")
            case .notApplied: String(localized: "無法設定 Finder 資料夾的圖示")
            }
        }
    }

    private static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "FolderIcons", directoryHint: .isDirectory)
    }

    private static func fileURL(for serverID: UUID) -> URL {
        directory.appending(path: "\(serverID.uuidString).png")
    }

    static func storedImage(for serverID: UUID) -> NSImage? {
        NSImage(contentsOf: fileURL(for: serverID))
    }

    static func store(_ image: NSImage, for serverID: UUID) throws {
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { throw Failure.unreadableImage }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: fileURL(for: serverID), options: .atomic)
    }

    static func removeStored(for serverID: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: serverID))
    }

    /// Puts the picture on the server's folder, or takes a custom icon off
    /// it when `image` is nil.
    ///
    /// Written by hand rather than through `NSWorkspace.setIcon`, which
    /// returns false for a sandboxed app even inside a folder it was handed:
    /// the icon goes in the resource fork of `Icon\r`, and a Finder flag on
    /// the folder tells Finder to look for it.
    static func apply(_ image: NSImage?, toFolderOf serverID: UUID) async throws {
        let folder = try await folderURL(of: serverID)
        let hasScopedAccess = folder.startAccessingSecurityScopedResource()
        defer { if hasScopedAccess { folder.stopAccessingSecurityScopedResource() } }
        let iconFile = folder.appending(path: iconFileName)
        if let image {
            guard let icns = icnsData(for: image) else { throw Failure.unreadableImage }
            if !FileManager.default.fileExists(atPath: iconFile.path) {
                guard FileManager.default.createFile(atPath: iconFile.path, contents: Data()) else {
                    throw Failure.notApplied
                }
            }
            try setAttribute(resourceForkAttribute, to: resourceFork(holding: icns), on: iconFile)
            // The file itself stays out of sight, as Finder's own does.
            try setFinderFlags(on: iconFile) { $0 | isInvisibleFlag }
            try setFinderFlags(on: folder) { $0 | hasCustomIconFlag }
        } else {
            try setFinderFlags(on: folder) { $0 & ~hasCustomIconFlag }
            if FileManager.default.fileExists(atPath: iconFile.path) {
                try FileManager.default.removeItem(at: iconFile)
            }
        }
    }

    static let iconFileName = "Icon\r"
    private static let resourceForkAttribute = "com.apple.ResourceFork"
    private static let finderInfoAttribute = "com.apple.FinderInfo"
    /// Bits in the big-endian flags at byte 8 of FinderInfo.
    private static let hasCustomIconFlag: UInt16 = 0x0400
    private static let isInvisibleFlag: UInt16 = 0x4000

    /// The picture as an icon family at every size Finder draws folders at.
    private static func icnsData(for image: NSImage) -> Data? {
        let squared = squaredImage(image)
        let data = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(data, "com.apple.icns" as CFString, 5, nil) else {
            return nil
        }
        for side in [16, 32, 128, 256, 512] {
            var rect = CGRect(x: 0, y: 0, width: side, height: side)
            guard let cgImage = squared.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
            CGImageDestinationAddImage(writer, cgImage, nil)
        }
        return CGImageDestinationFinalize(writer) ? data as Data : nil
    }

    /// Fitted into a square without stretching, as Finder would show it.
    private static func squaredImage(_ image: NSImage) -> NSImage {
        let side: CGFloat = 512
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { bounds in
            let scale = min(side / max(image.size.width, 1), side / max(image.size.height, 1))
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: NSRect(
                x: (side - size.width) / 2, y: (side - size.height) / 2,
                width: size.width, height: size.height))
            return true
        }
    }

    /// A classic resource fork with a single 'icns' resource of ID -16455,
    /// the one Finder reads a custom icon from.
    private static func resourceFork(holding icns: Data) -> Data {
        func bigEndian<T: FixedWidthInteger>(_ value: T) -> Data {
            withUnsafeBytes(of: value.bigEndian) { Data($0) }
        }
        let dataOffset: UInt32 = 256
        let resourceData = bigEndian(UInt32(icns.count)) + icns
        let mapOffset = dataOffset + UInt32(resourceData.count)

        var map = Data(count: 16 + 4 + 2)  // header copy, next map, file ref
        map += bigEndian(UInt16(0))  // attributes
        map += bigEndian(UInt16(28))  // type list offset, from the map's start
        map += bigEndian(UInt16(28 + 2 + 8 + 12))  // name list offset
        map += bigEndian(UInt16(0))  // number of types - 1
        map += Data("icns".utf8)
        map += bigEndian(UInt16(0))  // number of resources of this type - 1
        map += bigEndian(UInt16(2 + 8))  // reference list offset, from the type list
        map += bigEndian(Int16(-16455))
        map += bigEndian(UInt16(0xFFFF))  // no name
        map += Data([0, 0, 0, 0])  // attributes, and data offset 0
        map += bigEndian(UInt32(0))  // reserved handle

        var header = bigEndian(dataOffset) + bigEndian(mapOffset)
        header += bigEndian(UInt32(resourceData.count)) + bigEndian(UInt32(map.count))
        map.replaceSubrange(0..<16, with: header)
        return header + Data(count: Int(dataOffset) - header.count) + resourceData + map
    }

    private static func setFinderFlags(on url: URL, _ change: (UInt16) -> UInt16) throws {
        var info = (try? attribute(finderInfoAttribute, of: url)) ?? Data(count: 32)
        if info.count < 32 { info += Data(count: 32 - info.count) }
        let flags = UInt16(info[8]) << 8 | UInt16(info[9])
        let changed = change(flags)
        info[8] = UInt8(changed >> 8)
        info[9] = UInt8(changed & 0xFF)
        try setAttribute(finderInfoAttribute, to: info, on: url)
    }

    private static func attribute(_ name: String, of url: URL) throws -> Data {
        try url.withUnsafeFileSystemRepresentation { path in
            let length = getxattr(path, name, nil, 0, 0, 0)
            guard length >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            var data = Data(count: length)
            let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, length, 0, 0) }
            guard read >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            return data
        }
    }

    private static func setAttribute(_ name: String, to data: Data, on url: URL) throws {
        let result = url.withUnsafeFileSystemRepresentation { path in
            data.withUnsafeBytes { setxattr(path, name, $0.baseAddress, data.count, 0, 0) }
        }
        guard result == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    /// Puts the stored picture back on a folder that has lost it.
    static func restoreIfMissing(for serverID: UUID) async throws {
        guard let image = storedImage(for: serverID) else { return }
        let folder = try await folderURL(of: serverID)
        let hasScopedAccess = folder.startAccessingSecurityScopedResource()
        let hasIcon = FileManager.default.fileExists(atPath: folder.appending(path: iconFileName).path)
        if hasScopedAccess { folder.stopAccessingSecurityScopedResource() }
        guard !hasIcon else { return }
        try await apply(image, toFolderOf: serverID)
    }

    private static func folderURL(of serverID: UUID) async throws -> URL {
        try await FinderDomain.manager().getUserVisibleURL(
            for: ItemIdentifierMapper.identifier(for: .serverRoot(serverID)))
    }
}
