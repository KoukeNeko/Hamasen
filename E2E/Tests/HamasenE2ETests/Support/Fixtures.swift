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

import CryptoKit
import Foundation
@testable import HamasenCore

/// A seeded generator, so a failing run can be replayed exactly.
struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    /// SplitMix64.
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum Fixtures {
    /// Bytes that depend on the seed, so two files differ in content even
    /// when they have the same size.
    static func bytes(_ count: Int, seed: UInt64) -> Data {
        var generator = SeededGenerator(seed: seed)
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buffer in
            var index = 0
            while index < count {
                var word = generator.next()
                for _ in 0..<min(8, count - index) {
                    buffer[index] = UInt8(truncatingIfNeeded: word)
                    word >>= 8
                    index += 1
                }
            }
        }
        return data
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(fileAt url: URL) throws -> String {
        sha256(try Data(contentsOf: url, options: .mappedIfSafe))
    }

    static let scratch: URL = {
        let url = FileManager.default.temporaryDirectory.appending(path: "hamasen-e2e")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func file(_ data: Data) throws -> URL {
        let url = scratch.appending(path: UUID().uuidString)
        try data.write(to: url)
        return url
    }

    static func temporaryURL() -> URL {
        scratch.appending(path: UUID().uuidString)
    }

    /// Uploads `data` to `path` and returns its hash.
    @discardableResult
    static func upload(_ data: Data, to path: String, with service: any RemoteFileService) async throws -> String {
        let url = try file(data)
        defer { try? FileManager.default.removeItem(at: url) }
        try await service.uploadFile(from: url, to: path, progress: nil)
        return sha256(data)
    }

    /// Downloads `path` and returns its hash.
    static func downloadHash(_ path: String, with service: any RemoteFileService) async throws -> String {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try await service.downloadFile(at: path, to: url, progress: nil)
        return try sha256(fileAt: url)
    }

    /// Every item below `path`, depth first, as the client lists them.
    static func walk(_ path: String, with service: any RemoteFileService) async throws -> [RemoteItem] {
        var found: [RemoteItem] = []
        var pending = [path]
        while let directory = pending.popLast() {
            for item in try await service.listDirectory(at: directory) {
                found.append(item)
                if item.isDirectory { pending.append(item.path) }
            }
        }
        return found
    }
}
