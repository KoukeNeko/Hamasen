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

import Crypto
import Foundation

/// The key pair an S3-compatible service issues.
///
/// Named for the scheme rather than for Amazon: R2, MinIO, Backblaze and
/// Wasabi all hand out the same two strings under the same two names.
public struct AWSCredentials: Sendable, Equatable {
    public let accessKeyID: String
    public let secretAccessKey: String

    public init(accessKeyID: String, secretAccessKey: String) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
    }
}

/// Derives an AWS Signature Version 4 for one request.
///
/// Every S3-compatible service authenticates with this single scheme, so
/// getting it exactly right unlocks all of them at once. Exactness is not a
/// figure of speech: any deviation produces a 403 whose body says only that
/// the signature did not match, never which of the four derivation steps
/// produced the wrong bytes. That is why each step below is a separate
/// function the tests can pin individually, instead of one closed routine
/// that can only be checked at the end.
public enum AWSSignatureV4 {
    private static let algorithm = "AWS4-HMAC-SHA256"
    private static let terminator = "aws4_request"
    private static let secretPrefix = "AWS4"

    /// The service name in the credential scope. Every S3-compatible
    /// implementation expects this literal, including the ones that are not
    /// Amazon.
    public static let s3Service = "s3"

    /// Stands in for the body hash when the body is too large to hash before
    /// sending. Only safe over TLS, which is where it is used.
    public static let unsignedPayload = "UNSIGNED-PAYLOAD"

    /// What the signature covers.
    ///
    /// Every field has to match what actually goes on the wire. A header
    /// added after signing, or a path encoded differently by the URL loader,
    /// makes the server derive a different signature from the same request.
    public struct Request: Sendable {
        public let method: String
        /// The decoded path, with real "/" separators. Encoding it is this
        /// type's job because S3 does it differently from other AWS services.
        public let path: String
        public let queryItems: [URLQueryItem]
        /// Everything except `x-amz-date` and `x-amz-content-sha256`, which
        /// the signer adds itself so they cannot be left out by accident.
        public let headers: [String: String]
        public let payloadHash: String

        public init(
            method: String,
            path: String,
            queryItems: [URLQueryItem] = [],
            headers: [String: String],
            payloadHash: String
        ) {
            self.method = method
            self.path = path
            self.queryItems = queryItems
            self.headers = headers
            self.payloadHash = payloadHash
        }
    }

    // MARK: - Public entry point

    /// Returns every header the request needs in order to be accepted:
    /// the caller's own, plus the two `x-amz-` headers and `Authorization`.
    ///
    /// The returned dictionary is the complete set to apply, not a delta, so
    /// there is no way to sign one set of headers and send another.
    public static func signedHeaders(
        for request: Request,
        credentials: AWSCredentials,
        region: String,
        service: String = s3Service,
        signedAt: Date
    ) -> [String: String] {
        let timestamp = timestamp(from: signedAt)
        let day = String(timestamp.prefix(dayLength))

        var headers = request.headers
        headers[amazonDateHeader] = timestamp
        headers[contentHashHeader] = request.payloadHash

        let signed = Request(
            method: request.method,
            path: request.path,
            queryItems: request.queryItems,
            headers: headers,
            payloadHash: request.payloadHash
        )
        let canonical = canonicalRequest(for: signed)
        let scope = credentialScope(day: day, region: region, service: service)
        let toSign = stringToSign(
            canonicalRequest: canonical.text, timestamp: timestamp, scope: scope)
        let key = signingKey(
            secretAccessKey: credentials.secretAccessKey,
            day: day, region: region, service: service)

        headers[authorizationHeader] = """
            \(algorithm) \
            Credential=\(credentials.accessKeyID)/\(scope), \
            SignedHeaders=\(canonical.signedHeaders), \
            Signature=\(hexadecimal(hmac(key: key, message: toSign)))
            """
        return headers
    }

    /// The hash to declare for a body that is small enough to hold in memory.
    public static func payloadHash(of data: Data) -> String {
        hexadecimal(SHA256.hash(data: data))
    }

    // MARK: - Derivation steps

    static func credentialScope(day: String, region: String, service: String) -> String {
        [day, region, service, terminator].joined(separator: "/")
    }

    static func canonicalRequest(for request: Request) -> (text: String, signedHeaders: String) {
        let headers = canonicalHeaders(request.headers)
        let text = [
            request.method,
            canonicalURI(for: request.path),
            canonicalQueryString(for: request.queryItems),
            headers.text,
            headers.names,
            request.payloadHash,
        ].joined(separator: "\n")
        return (text, headers.names)
    }

    static func stringToSign(canonicalRequest: String, timestamp: String, scope: String) -> String {
        [
            algorithm,
            timestamp,
            scope,
            hexadecimal(SHA256.hash(data: Data(canonicalRequest.utf8))),
        ].joined(separator: "\n")
    }

    /// Four chained HMACs, each keyed by the result of the last. Chaining is
    /// what limits a leaked derived key to one day, one region and one
    /// service instead of the whole account.
    static func signingKey(
        secretAccessKey: String, day: String, region: String, service: String
    ) -> SymmetricKey {
        var key = SymmetricKey(data: Data("\(secretPrefix)\(secretAccessKey)".utf8))
        for component in [day, region, service, terminator] {
            key = SymmetricKey(data: hmac(key: key, message: component))
        }
        return key
    }

    // MARK: - Canonical forms

    /// RFC 3986's unreserved set, and nothing else. Notably not "+": some
    /// encoders emit it for a space, and S3 reads it as a literal plus.
    private static let unreservedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static let pathCharacters =
        unreservedCharacters.union(CharacterSet(charactersIn: "/"))

    static func canonicalURI(for path: String) -> String {
        let rooted = path.hasPrefix("/") ? path : "/" + path
        // S3 is the one AWS service that does not encode the path twice.
        // Encoding it twice here yields a signature that is correct for every
        // service except the only one this code talks to.
        return rooted.addingPercentEncoding(withAllowedCharacters: pathCharacters) ?? rooted
    }

    static func canonicalQueryString(for items: [URLQueryItem]) -> String {
        items
            .map { (encoded($0.name), encoded($0.value ?? "")) }
            .sorted { $0 < $1 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")
    }

    private static func canonicalHeaders(
        _ headers: [String: String]
    ) -> (text: String, names: String) {
        let normalized = headers
            .map { (name: $0.key.lowercased(), value: collapsingWhitespace(in: $0.value)) }
            .sorted { $0.name < $1.name }
        return (
            normalized.map { "\($0.name):\($0.value)\n" }.joined(),
            normalized.map(\.name).joined(separator: ";")
        )
    }

    /// A header's runs of whitespace collapse to one space and its ends are
    /// trimmed, because that is the form the server signs.
    private static func collapsingWhitespace(in value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func encoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreservedCharacters) ?? value
    }

    // MARK: - Primitives

    private static let amazonDateHeader = "x-amz-date"
    private static let contentHashHeader = "x-amz-content-sha256"
    private static let authorizationHeader = "Authorization"
    private static let dayLength = 8

    private static func hmac(key: SymmetricKey, message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key))
    }

    private static func hexadecimal(_ bytes: some Sequence<UInt8>) -> String {
        bytes.reduce(into: "") { $0 += String(format: "%02x", $1) }
    }

    /// ISO 8601 basic format in UTC, the only shape the scheme accepts.
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    private static func timestamp(from date: Date) -> String {
        timestampFormatter.string(from: date)
    }
}
