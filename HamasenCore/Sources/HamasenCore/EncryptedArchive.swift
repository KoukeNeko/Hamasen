import CommonCrypto
import Crypto
import Foundation

/// A payload sealed with a passphrase.
///
/// The parameters travel with the file rather than being assumed, so a file
/// written today can still be opened after they change: a reader takes the
/// salt and the work factor from what it is reading, and refuses anything
/// whose algorithms it does not know rather than guessing.
public struct EncryptedArchive: Codable, Equatable, Sendable {
    /// Passphrases are low-entropy, so the derivation is deliberately slow;
    /// this is the count OWASP gives for PBKDF2-HMAC-SHA256. It costs a
    /// fraction of a second once per export or import, and multiplies the
    /// cost of every guess by the same amount.
    public static let iterations = 600_000
    public static let keyDerivation = "PBKDF2-HMAC-SHA256"
    /// Authenticated: a file edited in transit fails to open rather than
    /// decrypting into something else.
    public static let cipher = "AES-256-GCM"

    public let keyDerivation: String
    public let iterations: Int
    public let salt: Data
    public let cipher: String
    /// Nonce, ciphertext and tag, as AES-GCM combines them.
    public let sealed: Data

    public enum ArchiveError: LocalizedError, Equatable {
        case unsupportedFormat
        case wrongPassphraseOrDamaged
        case derivationFailed
        case emptyPassphrase

        public var errorDescription: String? {
            switch self {
            case .unsupportedFormat:
                return String(localized: "這份加密備份使用這個版本不認得的加密方式", bundle: .module)
            case .wrongPassphraseOrDamaged:
                return String(localized: "密碼不正確，或這個檔案已損毀", bundle: .module)
            case .derivationFailed:
                return String(localized: "無法從密碼推導金鑰", bundle: .module)
            case .emptyPassphrase:
                return String(localized: "請設定一組密碼，加密備份不能沒有密碼", bundle: .module)
            }
        }
    }

    public static func seal(_ payload: Data, passphrase: String) throws -> EncryptedArchive {
        let salt = randomBytes(count: 16)
        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
        guard let combined = try AES.GCM.seal(payload, using: key).combined else {
            throw ArchiveError.derivationFailed
        }
        return EncryptedArchive(
            keyDerivation: keyDerivation,
            iterations: iterations,
            salt: salt,
            cipher: cipher,
            sealed: combined
        )
    }

    public func opened(passphrase: String) throws -> Data {
        guard keyDerivation == Self.keyDerivation, cipher == Self.cipher else {
            throw ArchiveError.unsupportedFormat
        }
        let key = try Self.deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key)
        } catch {
            // A wrong passphrase and a damaged file are the same failure here,
            // and saying which would tell an attacker something.
            throw ArchiveError.wrongPassphraseOrDamaged
        }
    }

    /// PBKDF2 rather than one of the fast derivations: the point is to be
    /// slow, so that guessing a passphrase costs what it should.
    private static func deriveKey(
        passphrase: String,
        salt: Data,
        iterations: Int
    ) throws -> SymmetricKey {
        // Empty is refused here rather than handed to CommonCrypto, whose
        // buffer for it has no address to pass.
        guard !passphrase.isEmpty else { throw ArchiveError.emptyPassphrase }

        var derived = [UInt8](repeating: 0, count: 32)
        let passphraseBytes = Array(passphrase.utf8)

        // Every pointer is used inside the closure that vends it. Returning
        // one and calling with it afterwards compiles and usually appears to
        // work, and is undefined: the buffer need not outlive the call.
        let status = passphraseBytes.withUnsafeBufferPointer { passphraseBuffer in
            salt.withUnsafeBytes { saltBuffer in
                derived.withUnsafeMutableBufferPointer { derivedBuffer in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        // Taken as bytes rather than as a C string, which is
                        // what the rebind spells; a passphrase may hold a
                        // zero byte and must not be cut short at one.
                        UnsafeRawPointer(passphraseBuffer.baseAddress!)
                            .assumingMemoryBound(to: CChar.self),
                        passphraseBuffer.count,
                        saltBuffer.bindMemory(to: UInt8.self).baseAddress,
                        saltBuffer.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        derivedBuffer.baseAddress!,
                        derivedBuffer.count
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw ArchiveError.derivationFailed }
        return SymmetricKey(data: Data(derived))
    }

    /// Seals with chosen parameters, so a test can prove a reader honours
    /// what the file records rather than what it would pick itself.
    static func sealForTesting(
        _ payload: Data,
        passphrase: String,
        salt: Data,
        iterations: Int
    ) throws -> EncryptedArchive {
        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
        guard let combined = try AES.GCM.seal(payload, using: key).combined else {
            throw ArchiveError.derivationFailed
        }
        return EncryptedArchive(
            keyDerivation: keyDerivation,
            iterations: iterations,
            salt: salt,
            cipher: cipher,
            sealed: combined
        )
    }

    /// From the same generator the keys come from, rather than a general
    /// purpose one.
    private static func randomBytes(count: Int) -> Data {
        SymmetricKey(size: .init(bitCount: count * 8)).withUnsafeBytes { Data($0) }
    }
}
