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

@Suite("S3ObjectKey")
struct S3ObjectKeyTests {
    @Test(arguments: [
        ("/my-bucket", "my-bucket", ""),
        ("/my-bucket/", "my-bucket", ""),
        ("my-bucket", "my-bucket", ""),
        ("/my-bucket/report.pdf", "my-bucket", "report.pdf"),
        ("/my-bucket/a/b/c.txt", "my-bucket", "a/b/c.txt"),
        ("/my-bucket/a/b/", "my-bucket", "a/b"),
    ])
    func splitsAServerPathIntoBucketAndKey(path: String, bucket: String, key: String) throws {
        let object = try S3ObjectKey(absolutePath: path)
        #expect(object.bucket == bucket)
        #expect(object.key == key)
    }

    /// A remote path of "/" names no bucket, which is a server the user has
    /// not finished configuring rather than a root to browse.
    @Test(arguments: ["/", "", "//"])
    func refusesAPathWithNoBucket(path: String) {
        #expect(throws: S3PathError.noBucketInPath(path)) {
            try S3ObjectKey(absolutePath: path)
        }
    }

    /// S3 stores keys as opaque strings, so an empty segment in the middle is
    /// somebody's real object name and must survive the round trip.
    @Test
    func keepsInteriorEmptySegments() throws {
        let object = try S3ObjectKey(absolutePath: "/bucket/a//b.txt")
        #expect(object.key == "a//b.txt")
        #expect(object.absolutePath == "/bucket/a//b.txt")
    }

    @Test
    func theBucketRootPrefixIsEmptyRatherThanASeparator() {
        // Asking S3 to list the prefix "/" returns nothing, because no key
        // starts with a separator.
        #expect(S3ObjectKey(bucket: "b", key: "").directoryPrefix == "")
        #expect(S3ObjectKey(bucket: "b", key: "photos").directoryPrefix == "photos/")
        #expect(S3ObjectKey(bucket: "b", key: "photos/2026").directoryPrefix == "photos/2026/")
    }

    @Test
    func absolutePathIsTheInverseOfParsing() throws {
        for path in ["/bucket", "/bucket/a", "/bucket/a/b.txt", "/bucket/資料 夾/報告.pdf"] {
            #expect(try S3ObjectKey(absolutePath: path).absolutePath == path)
        }
    }

    /// A trailing separator is part of the key, not decoration. It is the
    /// only thing that distinguishes an empty folder's marker from an object
    /// of the same name, and trimming it wrote the marker to the wrong key.
    @Test
    func aTrailingSeparatorSurvivesInAKey() {
        let marker = S3ObjectKey(bucket: "b", key: "photos/")
        #expect(marker.key == "photos/")
        #expect(marker.absolutePath == "/b/photos/")
        // And it is not doubled by asking for the prefix again.
        #expect(marker.directoryPrefix == "photos/")
    }

    @Test
    func theFolderMarkerIsAddressableAsAnObject() {
        let folder = S3ObjectKey(bucket: "b", key: "photos")
        #expect(folder.folderMarker.key == "photos/")
        #expect(folder.folderMarker.absolutePath == "/b/photos/")
        #expect(S3ObjectKey(bucket: "b", key: "").folderMarker.key == "")
    }

    /// A path's trailing separator is syntax rather than part of a name, so
    /// parsing one still drops it.
    @Test
    func parsingAPathStillDropsItsTrailingSeparator() throws {
        #expect(try S3ObjectKey(absolutePath: "/b/photos/").key == "photos")
    }

    @Test
    func appendingBuildsAChildKey() {
        let root = S3ObjectKey(bucket: "b", key: "")
        #expect(root.appending("photos").key == "photos")
        #expect(root.appending("photos").appending("a.jpg").key == "photos/a.jpg")
    }
}

@Suite("S3Endpoint")
struct S3EndpointTests {
    @Test(arguments: [
        ("s3.amazonaws.com", "us-east-1"),
        ("s3.eu-west-2.amazonaws.com", "eu-west-2"),
        ("s3-eu-west-1.amazonaws.com", "eu-west-1"),
        ("s3.dualstack.ap-northeast-1.amazonaws.com", "ap-northeast-1"),
        ("my-bucket.s3.us-west-2.amazonaws.com", "us-west-2"),
        ("abc123.r2.cloudflarestorage.com", "auto"),
        ("s3.wasabisys.com", "auto"),
        ("127.0.0.1", "auto"),
    ])
    func readsTheRegionOutOfAnAmazonHostname(host: String, region: String) {
        #expect(S3Endpoint.inferredRegion(forHost: host) == region)
    }

    private func endpoint(
        host: String, style: S3AddressingStyle = .automatic,
        scheme: String = "https", port: Int? = nil
    ) -> S3Endpoint {
        S3Endpoint(scheme: scheme, host: host, port: port,
                   region: S3Endpoint.inferredRegion(forHost: host), addressingStyle: style)
    }

    @Test
    func automaticPutsTheBucketInTheHostForAmazonAndInThePathForEveryoneElse() {
        #expect(endpoint(host: "s3.eu-west-2.amazonaws.com").resolvedStyle(for: "b") == .virtualHosted)
        #expect(endpoint(host: "abc123.r2.cloudflarestorage.com").resolvedStyle(for: "b") == .path)
        #expect(endpoint(host: "127.0.0.1").resolvedStyle(for: "b") == .path)
    }

    /// A wildcard certificate matches one label, so a dotted bucket in the
    /// hostname produces a TLS failure the user cannot do anything about.
    @Test
    func aDottedBucketIsAddressedByPathEvenWhenVirtualHostingIsAskedFor() {
        let aws = endpoint(host: "s3.us-east-1.amazonaws.com", style: .virtualHosted)
        #expect(aws.resolvedStyle(for: "plain") == .virtualHosted)
        #expect(aws.resolvedStyle(for: "my.bucket") == .path)

        // Without TLS there is no certificate to fail, so the choice stands.
        let plain = endpoint(host: "127.0.0.1", style: .virtualHosted, scheme: "http")
        #expect(plain.resolvedStyle(for: "my.bucket") == .virtualHosted)
    }

    @Test
    func buildsAPathStyleURL() throws {
        let address = try #require(endpoint(host: "abc123.r2.cloudflarestorage.com")
            .address(for: S3ObjectKey(bucket: "photos", key: "2026/a.jpg")))
        #expect(address.url.absoluteString
            == "https://abc123.r2.cloudflarestorage.com/photos/2026/a.jpg")
        #expect(address.signingPath == "/photos/2026/a.jpg")
        #expect(address.hostHeader == "abc123.r2.cloudflarestorage.com")
    }

    @Test
    func buildsAVirtualHostedURL() throws {
        let address = try #require(endpoint(host: "s3.us-west-2.amazonaws.com")
            .address(for: S3ObjectKey(bucket: "photos", key: "2026/a.jpg")))
        #expect(address.url.absoluteString
            == "https://photos.s3.us-west-2.amazonaws.com/2026/a.jpg")
        #expect(address.signingPath == "/2026/a.jpg")
        #expect(address.hostHeader == "photos.s3.us-west-2.amazonaws.com")
    }

    @Test
    func sortsAndEncodesTheQueryTheSameWayTheSignatureDoes() throws {
        let address = try #require(endpoint(host: "abc123.r2.cloudflarestorage.com")
            .address(for: S3ObjectKey(bucket: "photos", key: ""), queryItems: [
                URLQueryItem(name: "prefix", value: "2026/"),
                URLQueryItem(name: "list-type", value: "2"),
                URLQueryItem(name: "delimiter", value: "/"),
            ]))
        #expect(address.url.absoluteString
            == "https://abc123.r2.cloudflarestorage.com/photos"
            + "?delimiter=%2F&list-type=2&prefix=2026%2F")
    }

    /// The signature covers the Host header, so it has to be the one the URL
    /// loader will send — which omits a port the scheme already implies.
    @Test
    func theHostHeaderCarriesAPortOnlyWhenItIsNotTheSchemeDefault() throws {
        let loopback = endpoint(host: "127.0.0.1", scheme: "http", port: 8_333)
        let address = try #require(loopback.address(for: S3ObjectKey(bucket: "b", key: "x")))
        #expect(address.hostHeader == "127.0.0.1:8333")
        #expect(address.url.absoluteString == "http://127.0.0.1:8333/b/x")

        #expect(endpoint(host: "example.com", scheme: "https", port: 443)
            .hostHeader(for: "example.com") == "example.com")
        #expect(endpoint(host: "example.com", scheme: "http", port: 80)
            .hostHeader(for: "example.com") == "example.com")
    }

    /// The invariant the whole design rests on: whatever goes on the wire is
    /// byte-for-byte what the signature covered. Anything else is a 403 with
    /// no explanation.
    @Test(arguments: [
        "plain.txt", "two words.txt", "資料 夾/報告 v2.pdf",
        "a+b.txt", "a=b&c.txt", "100%.txt", "a~b_c-d.txt",
    ])
    func theURLPathIsExactlyWhatTheSignerWillEncode(key: String) throws {
        for style in [S3AddressingStyle.path, .virtualHosted] {
            let address = try #require(
                endpoint(host: "abc123.r2.cloudflarestorage.com", style: style)
                    .address(for: S3ObjectKey(bucket: "bucket", key: key)))
            let signed = AWSSignatureV4.canonicalURI(for: address.signingPath)
            #expect(address.url.absoluteString.hasSuffix(signed),
                    "\(style) \(key): the URL must end with the signed path")
        }
    }

    @Test("只有 loopback 位址才用明文 HTTP", arguments: [
        ("localhost", "http"), ("127.0.0.1", "http"), ("127.1.2.3", "http"),
        ("::1", "http"), ("[::1]", "http"),
        ("127.example.com", "https"), ("127.0.0.1.attacker.net", "https"),
        ("minio.local", "https"), ("s3.amazonaws.com", "https"),
    ])
    func plainHTTPIsUsedOnlyForALoopbackAddress(host: String, scheme: String) {
        #expect(S3Endpoint.scheme(forHost: host) == scheme)
    }

    @Test("IPv6 位址在 URL 與 Host 標頭中加上中括號")
    func bracketsARawIPv6Host() throws {
        let loopback = endpoint(host: "::1", scheme: "http", port: 9_000)
        let address = try #require(loopback.address(for: S3ObjectKey(bucket: "b", key: "x")))
        #expect(address.hostHeader == "[::1]:9000")
        #expect(address.url.absoluteString == "http://[::1]:9000/b/x")

        let typedWithBrackets = endpoint(host: "[::1]", scheme: "http", port: 9_000)
        #expect(typedWithBrackets.address(for: S3ObjectKey(bucket: "b", key: "x"))?.hostHeader == "[::1]:9000")
    }

    /// The bucket typed into the host, as Amazon's own console shows it, is
    /// not prefixed a second time.
    @Test
    func aHostThatAlreadyNamesTheBucketIsUsedAsIs() throws {
        let typed = endpoint(host: "photos.s3.us-west-2.amazonaws.com")
        let address = try #require(typed.address(for: S3ObjectKey(bucket: "photos", key: "x")))
        #expect(address.hostHeader == "photos.s3.us-west-2.amazonaws.com")
        #expect(address.url.absoluteString == "https://photos.s3.us-west-2.amazonaws.com/x")
    }

    /// A dotted bucket goes path-style over HTTPS; a host typed with that
    /// bucket in it must lose it, or the certificate cannot match.
    @Test
    func aDottedBucketInTheHostIsStrippedForPathStyle() throws {
        let typed = endpoint(host: "my.bucket.s3.us-east-1.amazonaws.com")
        let address = try #require(typed.address(for: S3ObjectKey(bucket: "my.bucket", key: "x")))
        #expect(address.hostHeader == "s3.us-east-1.amazonaws.com")
        #expect(address.url.absoluteString == "https://s3.us-east-1.amazonaws.com/my.bucket/x")
    }

    /// Off Amazon a host that starts like the bucket is just a name.
    @Test
    func aCustomHostIsNeverStripped() throws {
        let custom = endpoint(host: "photos.example.com")
        let address = try #require(custom.address(for: S3ObjectKey(bucket: "photos", key: "x")))
        #expect(address.hostHeader == "photos.example.com")
    }
}
