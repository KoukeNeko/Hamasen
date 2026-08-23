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
import Testing
@testable import HamasenCore

/// Pins every step of the signature, not just its last line.
///
/// A wrong signature is reported by every S3 service as one opaque 403, so a
/// test that only compared the final hex would say the same thing whether the
/// path was encoded wrongly, a header was missed, or the key chain was built
/// in the wrong order. Comparing the canonical request and the string to sign
/// as well is what turns a failure into a diff that names the mistake.
///
/// The expected values come from an independent implementation, anchored to
/// the worked example Amazon publishes for a ranged GET: `aws-documented-get-range`
/// reproduces the signature printed in that documentation, which is what makes
/// the other seven trustworthy.
struct AWSSignatureV4Tests {
    struct Vector: Sendable {
        let name: String
        let method: String
        let path: String
        let queryItems: [URLQueryItem]
        let callerHeaders: [String: String]
        let payloadHash: String
        let region: String
        let signedAt: Date
        let canonicalURI: String
        let canonicalQuery: String
        let canonicalRequest: String
        let stringToSign: String
        let signedHeaderNames: String
        let authorization: String
    }

    /// The example key pair from Amazon's documentation. Not a secret, and
    /// deliberately the same one the published worked example uses.
    static let credentials = AWSCredentials(
        accessKeyID: "AKIAIOSFODNN7EXAMPLE",
        secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")

    static let vectors: [Vector] = [
        Vector(
            name: "aws-documented-get-range",
            method: "GET",
            path: "/test.txt",
            queryItems: [],
            callerHeaders: ["Host": "examplebucket.s3.amazonaws.com", "Range": "bytes=0-9"],
            payloadHash: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            region: "us-east-1",
            signedAt: Date(timeIntervalSince1970: 1369353600),
            canonicalURI: "/test.txt",
            canonicalQuery: "",
            canonicalRequest: [
                "GET",
                "/test.txt",
                "",
                "host:examplebucket.s3.amazonaws.com",
                "range:bytes=0-9",
                "x-amz-content-sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
                "x-amz-date:20130524T000000Z",
                "",
                "host;range;x-amz-content-sha256;x-amz-date",
                "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            ].joined(separator: "\n"),
            stringToSign: [
                "AWS4-HMAC-SHA256",
                "20130524T000000Z",
                "20130524/us-east-1/s3/aws4_request",
                "7344ae5b7ee6c3e7e6b0fe0640412a37625d1fbfff95c48bbb2dc43964946972",
            ].joined(separator: "\n"),
            signedHeaderNames: "host;range;x-amz-content-sha256;x-amz-date",
            authorization: "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
        ),
        Vector(
            name: "r2-path-style-list",
            method: "GET",
            path: "/my-bucket",
            queryItems: [URLQueryItem(name: "list-type", value: "2"), URLQueryItem(name: "prefix", value: "photos/2026/"), URLQueryItem(name: "delimiter", value: "/")],
            callerHeaders: ["Host": "abc123.r2.cloudflarestorage.com"],
            payloadHash: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            region: "auto",
            signedAt: Date(timeIntervalSince1970: 1787458500),
            canonicalURI: "/my-bucket",
            canonicalQuery: "delimiter=%2F&list-type=2&prefix=photos%2F2026%2F",
            canonicalRequest: [
                "GET",
                "/my-bucket",
                "delimiter=%2F&list-type=2&prefix=photos%2F2026%2F",
                "host:abc123.r2.cloudflarestorage.com",
                "x-amz-content-sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
                "x-amz-date:20260823T041500Z",
                "",
                "host;x-amz-content-sha256;x-amz-date",
                "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            ].joined(separator: "\n"),
            stringToSign: [
                "AWS4-HMAC-SHA256",
                "20260823T041500Z",
                "20260823/auto/s3/aws4_request",
                "edff1cf879e4adb0ae58459abb6127a920123c5988298665585abe2cdaf4df69",
            ].joined(separator: "\n"),
            signedHeaderNames: "host;x-amz-content-sha256;x-amz-date",
            authorization: "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20260823/auto/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=4e1b6b47981b6a5ab31e36232a28b440c7cf9331b59a33c0ba113922130ae194"
        ),
        Vector(
            name: "query-sort-order",
            method: "GET",
            path: "/my-bucket",
            queryItems: [URLQueryItem(name: "prefix", value: "a/"), URLQueryItem(name: "list-type", value: "2"), URLQueryItem(name: "continuation-token", value: "1/abc=="), URLQueryItem(name: "max-keys", value: "1000"), URLQueryItem(name: "delimiter", value: "/")],
            callerHeaders: ["Host": "abc123.r2.cloudflarestorage.com"],
            payloadHash: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            region: "auto",
            signedAt: Date(timeIntervalSince1970: 1787458500),
            canonicalURI: "/my-bucket",
            canonicalQuery: "continuation-token=1%2Fabc%3D%3D&delimiter=%2F&list-type=2&max-keys=1000&prefix=a%2F",
            canonicalRequest: [
                "GET",
                "/my-bucket",
                "continuation-token=1%2Fabc%3D%3D&delimiter=%2F&list-type=2&max-keys=1000&prefix=a%2F",
                "host:abc123.r2.cloudflarestorage.com",
                "x-amz-content-sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
                "x-amz-date:20260823T041500Z",
                "",
                "host;x-amz-content-sha256;x-amz-date",
                "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            ].joined(separator: "\n"),
            stringToSign: [
                "AWS4-HMAC-SHA256",
                "20260823T041500Z",
                "20260823/auto/s3/aws4_request",
                "3582f89438648210652d5fb64b38ca43d1098e69e88753d2223491956984c2d6",
            ].joined(separator: "\n"),
            signedHeaderNames: "host;x-amz-content-sha256;x-amz-date",
            authorization: "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20260823/auto/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=66da6d24293f37c1180345fd8b3e17786edd99831c75aa0b673596dd73cd275a"
        ),
        Vector(
            name: "key-with-space-and-cjk",
            method: "PUT",
            path: "/my-bucket/資料 夾/報告 v2.pdf",
            queryItems: [],
            callerHeaders: ["Host": "abc123.r2.cloudflarestorage.com"],
            payloadHash: "93a23971a914e5eacbf0a8d25154cda309c3c1c72fbb9914d47c60f3cb681588",
            region: "auto",
            signedAt: Date(timeIntervalSince1970: 1787458500),
            canonicalURI: "/my-bucket/%E8%B3%87%E6%96%99%20%E5%A4%BE/%E5%A0%B1%E5%91%8A%20v2.pdf",
            canonicalQuery: "",
            canonicalRequest: [
                "PUT",
                "/my-bucket/%E8%B3%87%E6%96%99%20%E5%A4%BE/%E5%A0%B1%E5%91%8A%20v2.pdf",
                "",
                "host:abc123.r2.cloudflarestorage.com",
                "x-amz-content-sha256:93a23971a914e5eacbf0a8d25154cda309c3c1c72fbb9914d47c60f3cb681588",
                "x-amz-date:20260823T041500Z",
                "",
                "host;x-amz-content-sha256;x-amz-date",
                "93a23971a914e5eacbf0a8d25154cda309c3c1c72fbb9914d47c60f3cb681588",
            ].joined(separator: "\n"),
            stringToSign: [
                "AWS4-HMAC-SHA256",
                "20260823T041500Z",
                "20260823/auto/s3/aws4_request",
                "7d87d4a05f1459b5a624462227f5f5269b47c4ce9bf0771b671639c3f4e44c5f",
            ].joined(separator: "\n"),
            signedHeaderNames: "host;x-amz-content-sha256;x-amz-date",
            authorization: "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20260823/auto/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=b63f7819091434d1701f50a2fe45d000bdb2576039d27ccff60ab1baa8636adb"
        ),
        Vector(
            name: "put-with-payload",
            method: "PUT",
            path: "/my-bucket/notes.json",
            queryItems: [],
            callerHeaders: ["Content-Type": "application/json", "Host": "abc123.r2.cloudflarestorage.com"],
            payloadHash: "93a23971a914e5eacbf0a8d25154cda309c3c1c72fbb9914d47c60f3cb681588",
            region: "auto",
            signedAt: Date(timeIntervalSince1970: 1787458500),
            canonicalURI: "/my-bucket/notes.json",
            canonicalQuery: "",
            canonicalRequest: [
                "PUT",
                "/my-bucket/notes.json",
                "",
                "content-type:application/json",
                "host:abc123.r2.cloudflarestorage.com",
                "x-amz-content-sha256:93a23971a914e5eacbf0a8d25154cda309c3c1c72fbb9914d47c60f3cb681588",
                "x-amz-date:20260823T041500Z",
                "",
                "content-type;host;x-amz-content-sha256;x-amz-date",
                "93a23971a914e5eacbf0a8d25154cda309c3c1c72fbb9914d47c60f3cb681588",
            ].joined(separator: "\n"),
            stringToSign: [
                "AWS4-HMAC-SHA256",
                "20260823T041500Z",
                "20260823/auto/s3/aws4_request",
                "ee5459a7c7792145a20039307803c2086c948e677623b05ae70a11148cf8355e",
            ].joined(separator: "\n"),
            signedHeaderNames: "content-type;host;x-amz-content-sha256;x-amz-date",
            authorization: "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20260823/auto/s3/aws4_request, SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date, Signature=d63e467b4821688b19b770b2db5b8c5ba5e91db2bd2c9c3a4393d157421c9fee"
        ),
        Vector(
            name: "unsigned-payload",
            method: "PUT",
            path: "/my-bucket/big.bin",
            queryItems: [],
            callerHeaders: ["Host": "abc123.r2.cloudflarestorage.com"],
            payloadHash: "UNSIGNED-PAYLOAD",
            region: "auto",
            signedAt: Date(timeIntervalSince1970: 1787458500),
            canonicalURI: "/my-bucket/big.bin",
            canonicalQuery: "",
            canonicalRequest: [
                "PUT",
                "/my-bucket/big.bin",
                "",
                "host:abc123.r2.cloudflarestorage.com",
                "x-amz-content-sha256:UNSIGNED-PAYLOAD",
                "x-amz-date:20260823T041500Z",
                "",
                "host;x-amz-content-sha256;x-amz-date",
                "UNSIGNED-PAYLOAD",
            ].joined(separator: "\n"),
            stringToSign: [
                "AWS4-HMAC-SHA256",
                "20260823T041500Z",
                "20260823/auto/s3/aws4_request",
                "bdaa1d081a3a624d1f9a1ca1b1b52da75ddda7422cf6a66ed285cc69a71c6b44",
            ].joined(separator: "\n"),
            signedHeaderNames: "host;x-amz-content-sha256;x-amz-date",
            authorization: "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20260823/auto/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=7743cb58e3ebc66fb8daf5f41bb8b172cf47b90a9078d9bd25b2bebb0f758ce8"
        ),
        Vector(
            name: "header-whitespace",
            method: "GET",
            path: "/my-bucket/x.txt",
            queryItems: [],
            callerHeaders: ["Host": "abc123.r2.cloudflarestorage.com", "My-Header": "  a   b  c  "],
            payloadHash: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            region: "auto",
            signedAt: Date(timeIntervalSince1970: 1787458500),
            canonicalURI: "/my-bucket/x.txt",
            canonicalQuery: "",
            canonicalRequest: [
                "GET",
                "/my-bucket/x.txt",
                "",
                "host:abc123.r2.cloudflarestorage.com",
                "my-header:a b c",
                "x-amz-content-sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
                "x-amz-date:20260823T041500Z",
                "",
                "host;my-header;x-amz-content-sha256;x-amz-date",
                "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            ].joined(separator: "\n"),
            stringToSign: [
                "AWS4-HMAC-SHA256",
                "20260823T041500Z",
                "20260823/auto/s3/aws4_request",
                "743552cbf2cc8e5a3d923c109362fbeb4c093ee764cb31a70669d6c1ac1da091",
            ].joined(separator: "\n"),
            signedHeaderNames: "host;my-header;x-amz-content-sha256;x-amz-date",
            authorization: "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20260823/auto/s3/aws4_request, SignedHeaders=host;my-header;x-amz-content-sha256;x-amz-date, Signature=b26468d3098ebe757aa6cb415fbea3d48a1b282b12b0ffe61758c4ba3f0b8148"
        ),
        Vector(
            name: "multipart-uploads-subresource",
            method: "POST",
            path: "/my-bucket/big.bin",
            queryItems: [URLQueryItem(name: "uploads", value: "")],
            callerHeaders: ["Host": "abc123.r2.cloudflarestorage.com"],
            payloadHash: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            region: "auto",
            signedAt: Date(timeIntervalSince1970: 1787458500),
            canonicalURI: "/my-bucket/big.bin",
            canonicalQuery: "uploads=",
            canonicalRequest: [
                "POST",
                "/my-bucket/big.bin",
                "uploads=",
                "host:abc123.r2.cloudflarestorage.com",
                "x-amz-content-sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
                "x-amz-date:20260823T041500Z",
                "",
                "host;x-amz-content-sha256;x-amz-date",
                "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            ].joined(separator: "\n"),
            stringToSign: [
                "AWS4-HMAC-SHA256",
                "20260823T041500Z",
                "20260823/auto/s3/aws4_request",
                "0b38fc19c65969eb1444636d93c864d3c8e81e68cab2eb977dd292e39b466de1",
            ].joined(separator: "\n"),
            signedHeaderNames: "host;x-amz-content-sha256;x-amz-date",
            authorization: "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20260823/auto/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=e577a533a5ea2644e3bc73795b6b3dce902c5826903e343eb56a519e86bcf385"
        ),
    ]

    /// Rebuilds the full header set the signer works from: the caller's, plus
    /// the two the signer is responsible for adding.
    private func signedRequest(for vector: Vector) -> AWSSignatureV4.Request {
        var headers = vector.callerHeaders
        headers["x-amz-date"] = AWSSignatureV4Tests.timestamp(for: vector)
        headers["x-amz-content-sha256"] = vector.payloadHash
        return AWSSignatureV4.Request(
            method: vector.method,
            path: vector.path,
            queryItems: vector.queryItems,
            headers: headers,
            payloadHash: vector.payloadHash)
    }

    private static func timestamp(for vector: Vector) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: vector.signedAt)
    }

    @Test(arguments: vectors)
    func canonicalURIMatchesTheReference(vector: Vector) {
        #expect(AWSSignatureV4.canonicalURI(for: vector.path) == vector.canonicalURI,
                "\(vector.name): canonical URI")
    }

    @Test(arguments: vectors)
    func canonicalQueryStringMatchesTheReference(vector: Vector) {
        #expect(AWSSignatureV4.canonicalQueryString(for: vector.queryItems) == vector.canonicalQuery,
                "\(vector.name): canonical query string")
    }

    @Test(arguments: vectors)
    func canonicalRequestMatchesTheReference(vector: Vector) {
        let canonical = AWSSignatureV4.canonicalRequest(for: signedRequest(for: vector))
        #expect(canonical.text == vector.canonicalRequest, "\(vector.name): canonical request")
        #expect(canonical.signedHeaders == vector.signedHeaderNames,
                "\(vector.name): signed header names")
    }

    @Test(arguments: vectors)
    func stringToSignMatchesTheReference(vector: Vector) {
        let scope = AWSSignatureV4.credentialScope(
            day: String(AWSSignatureV4Tests.timestamp(for: vector).prefix(8)),
            region: vector.region,
            service: AWSSignatureV4.s3Service)
        let toSign = AWSSignatureV4.stringToSign(
            canonicalRequest: vector.canonicalRequest,
            timestamp: AWSSignatureV4Tests.timestamp(for: vector),
            scope: scope)
        #expect(toSign == vector.stringToSign, "\(vector.name): string to sign")
    }

    @Test(arguments: vectors)
    func authorizationHeaderMatchesTheReference(vector: Vector) {
        let headers = AWSSignatureV4.signedHeaders(
            for: AWSSignatureV4.Request(
                method: vector.method,
                path: vector.path,
                queryItems: vector.queryItems,
                headers: vector.callerHeaders,
                payloadHash: vector.payloadHash),
            credentials: AWSSignatureV4Tests.credentials,
            region: vector.region,
            signedAt: vector.signedAt)

        #expect(headers["Authorization"] == vector.authorization, "\(vector.name): authorization")
        #expect(headers["x-amz-content-sha256"] == vector.payloadHash,
                "\(vector.name): the signer must declare the payload hash it signed")
        #expect(headers["x-amz-date"] == AWSSignatureV4Tests.timestamp(for: vector),
                "\(vector.name): the signer must declare the timestamp it signed")
    }

    /// The published example is the anchor for everything above: if this one
    /// value ever stops matching Amazon's documentation, no other expectation
    /// in this file means anything.
    @Test
    func theAnchorReproducesTheSignatureAmazonPublishes() throws {
        let anchor = try #require(
            AWSSignatureV4Tests.vectors.first { $0.name == "aws-documented-get-range" })
        #expect(anchor.authorization.hasSuffix(
            "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"))

        let headers = AWSSignatureV4.signedHeaders(
            for: AWSSignatureV4.Request(
                method: anchor.method,
                path: anchor.path,
                headers: anchor.callerHeaders,
                payloadHash: anchor.payloadHash),
            credentials: AWSSignatureV4Tests.credentials,
            region: anchor.region,
            signedAt: anchor.signedAt)
        #expect(headers["Authorization"] == anchor.authorization)
    }

    /// A space must travel as %20. Encoders that emit "+" are common enough
    /// that this deserves its own name in the output.
    @Test
    func aSpaceIsPercentEncodedRatherThanTurnedIntoAPlus() {
        #expect(AWSSignatureV4.canonicalURI(for: "/bucket/two words.txt")
            == "/bucket/two%20words.txt")
        #expect(AWSSignatureV4.canonicalQueryString(
            for: [URLQueryItem(name: "prefix", value: "two words/")])
            == "prefix=two%20words%2F")
    }

    /// S3 alone among AWS services encodes the path once. Double encoding
    /// turns every "%" into "%25" and is the classic way to produce a
    /// signature that works nowhere.
    @Test
    func thePathIsEncodedOnceNotTwice() {
        #expect(AWSSignatureV4.canonicalURI(for: "/bucket/a b") == "/bucket/a%20b")
        #expect(AWSSignatureV4.canonicalURI(for: "/bucket/a%20b") == "/bucket/a%2520b")
    }
}
