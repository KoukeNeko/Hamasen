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
@testable import HamasenCore

/// Checks an arriving request's signature the way a real service does.
///
/// A fake that accepted anything would leave the hardest part of this feature
/// untested by every service-level test in the suite — and it is the part
/// whose failures arrive as a 403 that names no cause.
///
/// What this catches is *divergence*: the request that was signed differing
/// from the request that was sent. It cannot catch an encoding that is wrong
/// but consistent, because the client would then sign the same wrong bytes it
/// transmits; `S3AddressingTests` pins the encoding itself against an
/// independent reference.
enum TestS3SignatureVerifier {
    enum Failure: Error, Equatable, CustomStringConvertible {
        case missingAuthorization
        case malformedAuthorization(String)
        case unknownAccessKey(String)
        case missingSignedHeader(String)
        case signatureMismatch(expected: String, received: String)
        case payloadHashMismatch(declared: String, actual: String)

        var description: String {
            switch self {
            case .missingAuthorization:
                return "no Authorization header"
            case .malformedAuthorization(let header):
                return "malformed Authorization: \(header)"
            case .unknownAccessKey(let key):
                return "unknown access key \(key)"
            case .missingSignedHeader(let name):
                return "request claims to sign \(name) but does not carry it"
            case .signatureMismatch(let expected, let received):
                return "signature mismatch: expected \(expected), received \(received)"
            case .payloadHashMismatch(let declared, let actual):
                return "body hashes to \(actual) but x-amz-content-sha256 declares \(declared)"
            }
        }
    }

    /// - Parameter uri: the request target exactly as it arrived. Using the
    ///   raw bytes rather than anything re-derived is the whole point: a
    ///   client whose URL and signature disagree is what this exists to catch.
    static func verify(
        method: String,
        uri: String,
        headers: [(name: String, value: String)],
        body: Data,
        credentials: AWSCredentials
    ) throws {
        let lookup = Dictionary(
            headers.map { ($0.name.lowercased(), $0.value) }, uniquingKeysWith: { "\($0),\($1)" })

        guard let authorization = lookup["authorization"] else { throw Failure.missingAuthorization }
        let parts = try parseAuthorization(authorization)
        guard parts.accessKeyID == credentials.accessKeyID else {
            throw Failure.unknownAccessKey(parts.accessKeyID)
        }

        let declaredHash = lookup["x-amz-content-sha256"] ?? ""
        if declaredHash != AWSSignatureV4.unsignedPayload {
            let actual = AWSSignatureV4.payloadHash(of: body)
            guard actual == declaredHash else {
                throw Failure.payloadHashMismatch(declared: declaredHash, actual: actual)
            }
        }

        var canonicalHeaders = ""
        for name in parts.signedHeaders {
            guard let value = lookup[name] else { throw Failure.missingSignedHeader(name) }
            canonicalHeaders += "\(name):\(collapsingWhitespace(in: value))\n"
        }

        let split = uri.firstIndex(of: "?")
        let canonicalRequest = [
            method,
            split.map { String(uri[uri.startIndex..<$0]) } ?? uri,
            split.map { String(uri[uri.index(after: $0)...]) } ?? "",
            canonicalHeaders,
            parts.signedHeaders.joined(separator: ";"),
            declaredHash,
        ].joined(separator: "\n")

        let toSign = AWSSignatureV4.stringToSign(
            canonicalRequest: canonicalRequest,
            timestamp: lookup["x-amz-date"] ?? "",
            scope: parts.scope)
        let key = AWSSignatureV4.signingKey(
            secretAccessKey: credentials.secretAccessKey,
            day: parts.day, region: parts.region, service: parts.service)
        let expected = HMAC<SHA256>
            .authenticationCode(for: Data(toSign.utf8), using: key)
            .reduce(into: "") { $0 += String(format: "%02x", $1) }

        guard expected == parts.signature else {
            throw Failure.signatureMismatch(expected: expected, received: parts.signature)
        }
    }

    // MARK: - Authorization header

    private struct Parts {
        let accessKeyID: String
        let scope: String
        let day: String
        let region: String
        let service: String
        let signedHeaders: [String]
        let signature: String
    }

    private static func parseAuthorization(_ header: String) throws -> Parts {
        let expectedScopeComponents = 4
        guard header.hasPrefix("AWS4-HMAC-SHA256 ") else {
            throw Failure.malformedAuthorization(header)
        }
        var fields: [String: String] = [:]
        for field in header.dropFirst("AWS4-HMAC-SHA256 ".count).components(separatedBy: ",") {
            let trimmed = field.trimmingCharacters(in: .whitespaces)
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            fields[String(trimmed[trimmed.startIndex..<equals])] =
                String(trimmed[trimmed.index(after: equals)...])
        }
        guard let credential = fields["Credential"],
              let signedHeaders = fields["SignedHeaders"],
              let signature = fields["Signature"]
        else { throw Failure.malformedAuthorization(header) }

        let credentialParts = credential.components(separatedBy: "/")
        guard credentialParts.count == expectedScopeComponents + 1 else {
            throw Failure.malformedAuthorization(header)
        }
        return Parts(
            accessKeyID: credentialParts[0],
            scope: credentialParts.dropFirst().joined(separator: "/"),
            day: credentialParts[1],
            region: credentialParts[2],
            service: credentialParts[3],
            signedHeaders: signedHeaders.components(separatedBy: ";"),
            signature: signature)
    }

    private static func collapsingWhitespace(in value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
