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

@Suite("S3ListResponseParser")
struct S3ListResponseParserTests {
    private func parse(_ xml: String) throws -> S3ListResponseParser.Listing {
        try S3ListResponseParser.parse(Data(xml.utf8))
    }

    /// Amazon's shape: namespaced, url-encoded, with a storage class the
    /// parser has no use for.
    private static let amazon = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <Name>examplebucket</Name>
          <Prefix>photos/</Prefix>
          <Delimiter>/</Delimiter>
          <MaxKeys>1000</MaxKeys>
          <EncodingType>url</EncodingType>
          <KeyCount>2</KeyCount>
          <IsTruncated>false</IsTruncated>
          <Contents>
            <Key>photos/holiday%20snap.jpg</Key>
            <LastModified>2026-08-23T04:15:00.000Z</LastModified>
            <ETag>&quot;9b2cf5e1&quot;</ETag>
            <Size>204800</Size>
            <StorageClass>STANDARD</StorageClass>
          </Contents>
          <CommonPrefixes><Prefix>photos/2026/</Prefix></CommonPrefixes>
        </ListBucketResult>
        """

    /// R2's shape: no namespace, no encoding type, no storage class.
    private static let cloudflare = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult>
          <Name>my-bucket</Name>
          <Prefix></Prefix>
          <KeyCount>1</KeyCount>
          <MaxKeys>1000</MaxKeys>
          <IsTruncated>false</IsTruncated>
          <Contents>
            <Key>notes.txt</Key>
            <LastModified>2026-08-23T04:15:00Z</LastModified>
            <ETag>"abc"</ETag>
            <Size>17</Size>
          </Contents>
        </ListBucketResult>
        """

    /// MinIO's shape: an Owner block the parser must read past.
    private static let minio = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <Name>b</Name><Prefix>docs/</Prefix><Delimiter>/</Delimiter>
          <IsTruncated>false</IsTruncated><KeyCount>1</KeyCount>
          <Contents>
            <Key>docs/a.pdf</Key>
            <LastModified>2026-08-23T04:15:00.000Z</LastModified>
            <ETag>&quot;d41d8&quot;</ETag><Size>9</Size>
            <Owner><ID>minio</ID><DisplayName>minio</DisplayName></Owner>
            <StorageClass>STANDARD</StorageClass>
          </Contents>
          <CommonPrefixes><Prefix>docs/2026/</Prefix></CommonPrefixes>
        </ListBucketResult>
        """

    @Test
    func readsAmazonsListing() throws {
        let listing = try parse(Self.amazon)
        #expect(listing.objects.count == 1)
        #expect(listing.objects[0].key == "photos/holiday snap.jpg")
        #expect(listing.objects[0].size == 204_800)
        #expect(listing.objects[0].lastModified
            == Date(timeIntervalSince1970: 1_787_458_500))
        #expect(listing.commonPrefixes == ["photos/2026/"])
        #expect(listing.isTruncated == false)
        #expect(listing.nextContinuationToken == nil)
    }

    @Test
    func readsCloudflaresListingWithoutTheOptionalElements() throws {
        let listing = try parse(Self.cloudflare)
        #expect(listing.objects.count == 1)
        #expect(listing.objects[0].key == "notes.txt")
        #expect(listing.objects[0].size == 17)
        // No fractional part, and it still has to parse.
        #expect(listing.objects[0].lastModified
            == Date(timeIntervalSince1970: 1_787_458_500))
        #expect(listing.commonPrefixes.isEmpty)
    }

    @Test
    func readsPastMinIOsOwnerBlock() throws {
        let listing = try parse(Self.minio)
        #expect(listing.objects.map(\.key) == ["docs/a.pdf"])
        #expect(listing.commonPrefixes == ["docs/2026/"])
    }

    /// The listing echoes the prefix it was asked for under the same element
    /// name that CommonPrefixes gives its children. Reporting the echo would
    /// show every directory as containing itself, and Finder would recurse.
    @Test
    func theEchoedRequestPrefixIsNotAFolder() throws {
        #expect(try parse(Self.amazon).commonPrefixes == ["photos/2026/"])
        #expect(try parse(Self.minio).commonPrefixes == ["docs/2026/"])
    }

    /// The token is opaque and not among the fields `encoding-type=url`
    /// applies to, so it goes back exactly as it came.
    @Test
    func carriesTheContinuationTokenOfATruncatedListing() throws {
        let listing = try parse("""
            <ListBucketResult>
              <Name>b</Name><IsTruncated>true</IsTruncated>
              <NextContinuationToken>1ueGcxLPRx1Tr%2F</NextContinuationToken>
              <EncodingType>url</EncodingType>
              <Contents><Key>a</Key><Size>1</Size>
                <LastModified>2026-08-23T04:15:00Z</LastModified></Contents>
            </ListBucketResult>
            """)
        #expect(listing.isTruncated)
        #expect(listing.nextContinuationToken == "1ueGcxLPRx1Tr%2F")
    }

    /// EncodingType can arrive after the keys it applies to, so decoding
    /// cannot happen as the document streams.
    @Test
    func decodesKeysEvenWhenTheEncodingTypeArrivesLast() throws {
        let listing = try parse("""
            <ListBucketResult>
              <Name>b</Name><IsTruncated>false</IsTruncated>
              <Contents><Key>a%20b.txt</Key><Size>1</Size></Contents>
              <CommonPrefixes><Prefix>c%20d/</Prefix></CommonPrefixes>
              <EncodingType>url</EncodingType>
            </ListBucketResult>
            """)
        #expect(listing.objects.map(\.key) == ["a b.txt"])
        #expect(listing.commonPrefixes == ["c d/"])
    }

    /// A server that ignored the parameter sends raw keys, and decoding those
    /// would rename an object whose name genuinely contains a percent sign.
    @Test
    func leavesAPercentAloneWhenTheServerDidNotEncode() throws {
        let listing = try parse("""
            <ListBucketResult>
              <Name>b</Name><IsTruncated>false</IsTruncated>
              <Contents><Key>100%20off.txt</Key><Size>1</Size></Contents>
            </ListBucketResult>
            """)
        #expect(listing.objects.map(\.key) == ["100%20off.txt"])
    }

    @Test
    func anEmptyBucketListsNothingRatherThanFailing() throws {
        let listing = try parse("""
            <ListBucketResult><Name>b</Name><KeyCount>0</KeyCount>
            <IsTruncated>false</IsTruncated></ListBucketResult>
            """)
        #expect(listing.objects.isEmpty)
        #expect(listing.commonPrefixes.isEmpty)
    }

    @Test
    func rejectsABodyThatIsNotAListing() {
        #expect(throws: S3ListResponseParser.ParseError.notAListing) {
            try S3ListResponseParser.parse(Data("<Error><Code>AccessDenied</Code></Error>".utf8))
        }
        #expect(throws: S3ListResponseParser.ParseError.notXML) {
            try S3ListResponseParser.parse(Data("<html>nope".utf8))
        }
    }
}

@Suite("S3ErrorResponse")
struct S3ErrorResponseTests {
    private func body(_ code: String, _ message: String) -> Data {
        Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <Error><Code>\(code)</Code><Message>\(message)</Message>
            <RequestId>abc</RequestId></Error>
            """.utf8)
    }

    private func mapped(_ data: Data?, status: Int) -> RemoteFileServiceError {
        S3ErrorResponse.remoteError(
            status: status, body: data, operation: "讀取", path: "/bucket/a.txt")
    }

    @Test
    func readsTheCodeAndMessage() throws {
        let parsed = try #require(S3ErrorResponse.parse(
            body("NoSuchKey", "The specified key does not exist.")))
        #expect(parsed.code == "NoSuchKey")
        #expect(parsed.message == "The specified key does not exist.")
    }

    @Test(arguments: ["NoSuchKey", "NoSuchBucket", "NotFound"])
    func aMissingObjectBecomesItemNotFound(code: String) {
        #expect(mapped(body(code, "gone"), status: 404)
            == .itemNotFound(path: "/bucket/a.txt"))
    }

    @Test(arguments: ["InvalidAccessKeyId", "SignatureDoesNotMatch", "ExpiredToken", "InvalidToken"])
    func aRejectedKeyBecomesAuthenticationFailed(code: String) {
        #expect(mapped(body(code, "no"), status: 403) == .authenticationFailed)
    }

    /// A policy refusing one object says nothing about the key; reporting it
    /// as bad credentials would put the whole domain into a sign-in state.
    @Test(arguments: ["AccessDenied", "AllAccessDisabled", "AccountProblem"])
    func aPolicyRefusalBecomesPermissionDenied(code: String) {
        #expect(mapped(body(code, "no"), status: 403)
            == .permissionDenied(operation: "讀取", path: "/bucket/a.txt"))
    }

    @Test
    func aBare403IsAPermissionUnlessTheRequestMustSucceedForAnyKey() {
        #expect(mapped(nil, status: 403)
            == .permissionDenied(operation: "讀取", path: "/bucket/a.txt"))
        #expect(S3ErrorResponse.remoteError(
            status: 403, body: nil, operation: "連線", path: "/",
            forbiddenMeansCredentials: true) == .authenticationFailed)
    }

    @Test
    func readsEveryErrorEmbeddedInADeleteResult() {
        let xml = """
            <DeleteResult><Deleted><Key>a</Key></Deleted>
            <Error><Key>b</Key><Code>AccessDenied</Code><Message>Access Denied</Message></Error>
            <Error><Key>c</Key><Code>InternalError</Code><Message>oops</Message></Error>
            </DeleteResult>
            """
        let errors = S3ErrorResponse.embeddedErrors(in: Data(xml.utf8))
        #expect(errors.map(\.code) == ["AccessDenied", "InternalError"])
        #expect(S3ErrorResponse.embeddedErrors(
            in: Data("<CopyObjectResult><ETag>x</ETag></CopyObjectResult>".utf8)).isEmpty)
    }

    /// A skewed clock arrives as a 403. Reported as bad credentials it sends
    /// the user to re-enter a key that was never the problem.
    @Test
    func aNamedCodeOutranksWhatTheStatusWouldImply() {
        let error = mapped(
            body("RequestTimeTooSkewed", "The difference between the request time and the current time is too large."),
            status: 403)
        guard case .operationFailed(_, _, let underlying) = error else {
            Issue.record("expected operationFailed, got \(error)")
            return
        }
        #expect(underlying.contains("RequestTimeTooSkewed"))
        #expect(underlying.contains("difference between the request time"))
    }

    /// HEAD carries no body, so the status is all there is to go on.
    @Test
    func fallsBackToTheStatusWhenThereIsNoBodyToRead() {
        #expect(mapped(nil, status: 404) == .itemNotFound(path: "/bucket/a.txt"))
        #expect(mapped(nil, status: 403) == .permissionDenied(operation: "讀取", path: "/bucket/a.txt"))
        #expect(mapped(nil, status: 401) == .authenticationFailed)
        #expect(mapped(nil, status: 500)
            == .operationFailed(operation: "讀取", path: "/bucket/a.txt", underlying: "HTTP 500"))
    }

    /// A proxy in front of the bucket answers with its own page.
    @Test
    func survivesABodyThatIsNotAnErrorDocument() {
        #expect(S3ErrorResponse.parse(Data("<html><body>502</body></html>".utf8)) == nil)
        #expect(mapped(Data("<html>502 Bad Gateway".utf8), status: 502)
            == .operationFailed(operation: "讀取", path: "/bucket/a.txt", underlying: "HTTP 502"))
    }
}
