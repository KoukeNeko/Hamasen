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

/// A parsed OpenSSH private key file (the `openssh-key-v1` container written
/// by `ssh-keygen`).
///
/// Only the header is decoded — enough to know which key type it holds and
/// whether it is passphrase-protected, so the app can pick the right
/// authentication method and report precise errors before attempting a
/// connection. The key material itself stays untouched and is handed to
/// Citadel verbatim.
public struct OpenSSHPrivateKey: Sendable, Equatable {
    /// Key algorithms this app can authenticate with.
    public enum KeyType: String, Sendable, CaseIterable {
        case ed25519 = "ssh-ed25519"
        case rsa = "ssh-rsa"

        public var displayName: String {
            switch self {
            case .ed25519: return "Ed25519"
            case .rsa: return "RSA"
            }
        }
    }

    public enum ParseError: Error, Equatable {
        /// Not an OpenSSH key file at all.
        case notAnOpenSSHKey
        /// A PEM key in the older PKCS#1/SEC1 form ("BEGIN RSA PRIVATE KEY").
        case legacyPEMFormat
        /// Structurally an OpenSSH key, but the payload is unreadable.
        case malformed
        /// A valid OpenSSH key of an algorithm this app cannot use.
        case unsupportedKeyType(String)
    }

    private static let header = "-----BEGIN OPENSSH PRIVATE KEY-----"
    private static let footer = "-----END OPENSSH PRIVATE KEY-----"
    private static let legacyHeaderMarker = "PRIVATE KEY-----"
    private static let magic = "openssh-key-v1"
    private static let noCipher = "none"

    public let keyType: KeyType
    /// True when the key is protected by a passphrase.
    public let isEncrypted: Bool

    /// Parses the header of an OpenSSH private key file.
    public static func parse(_ keyText: String) throws -> OpenSSHPrivateKey {
        let trimmed = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(header) else {
            // Distinguish the common "wrong PEM flavour" case so the UI can
            // tell the user to convert the key instead of just failing.
            if trimmed.hasPrefix("-----BEGIN"), trimmed.contains(legacyHeaderMarker) {
                throw ParseError.legacyPEMFormat
            }
            throw ParseError.notAnOpenSSHKey
        }
        guard trimmed.hasSuffix(footer) else { throw ParseError.notAnOpenSSHKey }

        let base64Body = trimmed
            .dropFirst(header.count)
            .dropLast(footer.count)
            .filter { !$0.isWhitespace }
        guard let blob = Data(base64Encoded: String(base64Body)) else {
            throw ParseError.malformed
        }
        return try parseBlob(blob)
    }

    /// Decodes the `openssh-key-v1` container:
    /// magic, cipher name, KDF name, KDF options, key count, public key blob.
    private static func parseBlob(_ blob: Data) throws -> OpenSSHPrivateKey {
        var reader = ByteReader(blob)

        guard let magicBytes = reader.readBytes(count: magic.utf8.count + 1),
              String(decoding: magicBytes.dropLast(), as: UTF8.self) == magic,
              magicBytes.last == 0
        else {
            throw ParseError.malformed
        }

        guard let cipherName = reader.readString(),
              reader.readString() != nil, // kdfname
              reader.readLengthPrefixedBytes() != nil, // kdfoptions
              reader.readUInt32() != nil, // number of keys
              let publicKeyBlob = reader.readLengthPrefixedBytes()
        else {
            throw ParseError.malformed
        }

        var publicKeyReader = ByteReader(Data(publicKeyBlob))
        guard let keyTypeName = publicKeyReader.readString() else {
            throw ParseError.malformed
        }
        guard let keyType = KeyType(rawValue: keyTypeName) else {
            throw ParseError.unsupportedKeyType(keyTypeName)
        }

        return OpenSSHPrivateKey(keyType: keyType, isEncrypted: cipherName != noCipher)
    }
}

extension OpenSSHPrivateKey.ParseError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notAnOpenSSHKey:
            return String(localized: "這不是 OpenSSH 私密金鑰檔案", bundle: .module)
        case .legacyPEMFormat:
            return String(localized: "這是舊式 PEM 金鑰，請以 ssh-keygen -p -f <金鑰> 轉換為 OpenSSH 格式", bundle: .module)
        case .malformed:
            return String(localized: "金鑰檔案內容損毀或格式不正確", bundle: .module)
        case .unsupportedKeyType(let keyTypeName):
            return String(localized: "不支援的金鑰類型：\(keyTypeName)（目前支援 Ed25519 與 RSA）", bundle: .module)
        }
    }
}

/// Minimal big-endian reader for the SSH wire format, where variable-length
/// fields are a UInt32 length followed by that many bytes.
private struct ByteReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) {
        self.bytes = Array(data)
    }

    mutating func readBytes(count: Int) -> [UInt8]? {
        guard count >= 0, offset + count <= bytes.count else { return nil }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }

    mutating func readUInt32() -> UInt32? {
        guard let raw = readBytes(count: 4) else { return nil }
        return raw.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    mutating func readLengthPrefixedBytes() -> [UInt8]? {
        // A UInt32 always fits in Int on the 64-bit platforms this ships on,
        // and readBytes rejects lengths that run past the buffer.
        guard let length = readUInt32() else { return nil }
        return readBytes(count: Int(length))
    }

    mutating func readString() -> String? {
        guard let raw = readLengthPrefixedBytes() else { return nil }
        return String(decoding: raw, as: UTF8.self)
    }
}
