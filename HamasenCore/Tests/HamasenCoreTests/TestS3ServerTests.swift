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

/// Tests the harness, not the app.
///
/// Everything in step 5 onward is measured against this server, so a fault in
/// it would be read as a fault in the client — or worse, would hide one. The
/// signature checks below are the ones that matter: they prove the server can
/// tell a good request from a tampered one, which is the only reason building
/// it was worth more than a stub.
@Suite("TestS3Server")
struct TestS3ServerTests {
    private struct Response {
        let status: Int
        let data: Data
        var text: String { String(decoding: data, as: UTF8.self) }
    }

    private func send(
        _ method: String,
        key: String = "",
        query: [URLQueryItem] = [],
        body: Data = Data(),
        headers: [String: String] = [:],
        on server: TestS3Server,
        credentials: AWSCredentials = TestS3Server.credentials,
        tamper: ((URL) -> URL)? = nil
    ) async throws -> Response {
        let object = S3ObjectKey(bucket: TestS3Server.bucket, key: key)
        let address = try #require(server.endpoint.address(for: object, queryItems: query))

        var signable = headers
        signable["Host"] = address.hostHeader
        let signed = AWSSignatureV4.signedHeaders(
            for: AWSSignatureV4.Request(
                method: method, path: address.signingPath, queryItems: query,
                headers: signable, payloadHash: AWSSignatureV4.payloadHash(of: body)),
            credentials: credentials,
            region: server.endpoint.region,
            signedAt: Date())

        var request = URLRequest(url: tamper?(address.url) ?? address.url)
        request.httpMethod = method
        for (name, value) in signed where name.lowercased() != "host" {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if !body.isEmpty { request.httpBody = body }

        let (data, response) = try await URLSession.shared.data(for: request)
        return Response(status: (response as? HTTPURLResponse)?.statusCode ?? -1, data: data)
    }

    private func withServer(
        _ behaviour: TestS3Server.Behaviour = .wellBehaved,
        _ work: (TestS3Server) async throws -> Void
    ) async throws {
        let server = try await TestS3Server.start(behaviour: behaviour)
        do {
            try await work(server)
        } catch {
            try? await server.stop()
            throw error
        }
        try await server.stop()
    }

    // MARK: - The signature check

    @Test
    func acceptsACorrectlySignedRequest() async throws {
        try await withServer { server in
            let response = try await send("HEAD", on: server)
            #expect(response.status == 200)
        }
    }

    /// The point of the whole verifier: a URL that changed after it was signed
    /// must be refused, because that is what a client whose encoder and signer
    /// disagree produces.
    @Test
    func refusesARequestWhoseURLChangedAfterSigning() async throws {
        try await withServer { server in
            server.store.put(Data("hello".utf8), forKey: "a.txt")
            server.store.put(Data("secret".utf8), forKey: "b.txt")
            let response = try await send("GET", key: "a.txt", on: server) { url in
                URL(string: url.absoluteString.replacingOccurrences(of: "a.txt", with: "b.txt"))!
            }
            #expect(response.status == 403)
            #expect(response.text.contains("SignatureDoesNotMatch"))
        }
    }

    @Test
    func refusesARequestSignedWithTheWrongSecret() async throws {
        try await withServer { server in
            let wrong = AWSCredentials(
                accessKeyID: TestS3Server.credentials.accessKeyID,
                secretAccessKey: "not-the-secret")
            let response = try await send("HEAD", on: server, credentials: wrong)
            #expect(response.status == 403)
        }
    }

    @Test
    func refusesAnUnknownAccessKey() async throws {
        try await withServer { server in
            let stranger = AWSCredentials(accessKeyID: "AKIASTRANGER", secretAccessKey: "x")
            let response = try await send("HEAD", on: server, credentials: stranger)
            #expect(response.status == 403)
        }
    }

    @Test
    func refusesABucketItDoesNotHave() async throws {
        try await withServer { server in
            let object = S3ObjectKey(bucket: "somebody-elses", key: "a")
            let address = try #require(server.endpoint.address(for: object))
            let signed = AWSSignatureV4.signedHeaders(
                for: AWSSignatureV4.Request(
                    method: "GET", path: address.signingPath,
                    headers: ["Host": address.hostHeader],
                    payloadHash: AWSSignatureV4.payloadHash(of: Data())),
                credentials: TestS3Server.credentials,
                region: server.endpoint.region, signedAt: Date())
            var request = URLRequest(url: address.url)
            for (name, value) in signed where name.lowercased() != "host" {
                request.setValue(value, forHTTPHeaderField: name)
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 404)
            #expect(String(decoding: data, as: UTF8.self).contains("NoSuchBucket"))
        }
    }

    // MARK: - Objects

    @Test
    func storesAndReturnsAnObject() async throws {
        try await withServer { server in
            let payload = Data("哈瑪星".utf8)
            let stored = try await send("PUT", key: "docs/a.txt", body: payload, on: server)
            #expect(stored.status == 200)
            let fetched = try await send("GET", key: "docs/a.txt", on: server)
            #expect(fetched.status == 200)
            #expect(fetched.data == payload)
            let probed = try await send("HEAD", key: "docs/a.txt", on: server)
            #expect(probed.status == 200)
            let deleted = try await send("DELETE", key: "docs/a.txt", on: server)
            #expect(deleted.status == 204)
            let gone = try await send("HEAD", key: "docs/a.txt", on: server)
            #expect(gone.status == 404)
        }
    }

    @Test
    func servesAByteRange() async throws {
        try await withServer { server in
            server.store.put(Data("0123456789".utf8), forKey: "n.txt")
            let middle = try await send(
                "GET", key: "n.txt", headers: ["Range": "bytes=2-5"], on: server)
            #expect(middle.status == 206)
            #expect(middle.text == "2345")

            let tail = try await send(
                "GET", key: "n.txt", headers: ["Range": "bytes=7-"], on: server)
            #expect(tail.text == "789")
        }
    }

    /// A key with a space and non-ASCII has to survive signing, the URL, and
    /// the server's own decoding.
    @Test
    func handlesAKeyThatNeedsEncoding() async throws {
        try await withServer { server in
            let key = "資料 夾/報告 v2.txt"
            let stored = try await send("PUT", key: key, body: Data("x".utf8), on: server)
            #expect(stored.status == 200)
            #expect(server.store.object(forKey: key)?.data == Data("x".utf8))
            let fetched = try await send("GET", key: key, on: server)
            #expect(fetched.text == "x")
        }
    }

    // MARK: - Listing

    private func seed(_ server: TestS3Server) {
        for key in ["a.txt", "photos/", "photos/1.jpg", "photos/2.jpg",
                    "photos/raw/3.dng", "notes/x.md"] {
            server.store.put(Data(key.utf8), forKey: key)
        }
    }

    @Test
    func groupsAListingAtTheDelimiter() async throws {
        try await withServer { server in
            seed(server)
            let response = try await send("GET", query: [
                URLQueryItem(name: "list-type", value: "2"),
                URLQueryItem(name: "delimiter", value: "/"),
                URLQueryItem(name: "encoding-type", value: "url"),
            ], on: server)
            let listing = try S3ListResponseParser.parse(response.data)
            #expect(listing.objects.map(\.key) == ["a.txt"])
            #expect(listing.commonPrefixes == ["notes/", "photos/"])
        }
    }

    /// The zero-byte marker of an empty folder comes back as an object whose
    /// name after the prefix is empty. Real services do this too, and the
    /// client is what has to filter it — so the harness must not.
    @Test
    func reportsTheFolderMarkerAsAnObject() async throws {
        try await withServer { server in
            seed(server)
            let response = try await send("GET", query: [
                URLQueryItem(name: "list-type", value: "2"),
                URLQueryItem(name: "prefix", value: "photos/"),
                URLQueryItem(name: "delimiter", value: "/"),
            ], on: server)
            let listing = try S3ListResponseParser.parse(response.data)
            #expect(listing.objects.map(\.key) == ["photos/", "photos/1.jpg", "photos/2.jpg"])
            #expect(listing.commonPrefixes == ["photos/raw/"])
        }
    }

    @Test
    func paginatesWithAContinuationToken() async throws {
        try await withServer(TestS3Server.Behaviour(maxKeysPerPage: 2)) { server in
            seed(server)
            var seen: [String] = []
            var token: String?
            var rounds = 0
            repeat {
                var query = [URLQueryItem(name: "list-type", value: "2")]
                if let token { query.append(URLQueryItem(name: "continuation-token", value: token)) }
                let listing = try S3ListResponseParser.parse(
                    try await send("GET", query: query, on: server).data)
                seen += listing.objects.map(\.key)
                token = listing.nextContinuationToken
                rounds += 1
            } while token != nil && rounds < 10

            #expect(rounds == 3)
            #expect(seen == server.store.sortedKeys())
        }
    }

    /// A provider that ignores encoding-type sends raw keys, which the parser
    /// must then leave alone.
    @Test
    func canPretendToIgnoreTheEncodingType() async throws {
        try await withServer(TestS3Server.Behaviour(ignoresEncodingType: true)) { server in
            server.store.put(Data(), forKey: "100%20off.txt")
            let listing = try S3ListResponseParser.parse(try await send("GET", query: [
                URLQueryItem(name: "list-type", value: "2"),
                URLQueryItem(name: "encoding-type", value: "url"),
            ], on: server).data)
            #expect(listing.objects.map(\.key) == ["100%20off.txt"])
        }
    }

    // MARK: - Copy, batch delete, multipart

    @Test
    func copiesAnObject() async throws {
        try await withServer { server in
            server.store.put(Data("payload".utf8), forKey: "from.txt")
            let response = try await send(
                "PUT", key: "to.txt",
                headers: ["x-amz-copy-source": "/\(TestS3Server.bucket)/from.txt"], on: server)
            #expect(response.status == 200)
            #expect(server.store.object(forKey: "to.txt")?.data == Data("payload".utf8))
            #expect(server.store.object(forKey: "from.txt") != nil)
        }
    }

    @Test
    func deletesABatchOfKeys() async throws {
        try await withServer { server in
            seed(server)
            let body = Data("""
                <Delete><Object><Key>a.txt</Key></Object>\
                <Object><Key>notes/x.md</Key></Object></Delete>
                """.utf8)
            let response = try await send(
                "POST", query: [URLQueryItem(name: "delete", value: "")],
                body: body, on: server)
            #expect(response.status == 200)
            #expect(server.store.object(forKey: "a.txt") == nil)
            #expect(server.store.object(forKey: "notes/x.md") == nil)
            #expect(server.store.object(forKey: "photos/1.jpg") != nil)
        }
    }

    @Test
    func assemblesAMultipartUpload() async throws {
        try await withServer { server in
            let initiated = try await send(
                "POST", key: "big.bin", query: [URLQueryItem(name: "uploads", value: "")],
                on: server)
            let uploadID = try #require(
                S3Handler.values(ofElement: "uploadid", in: initiated.data).first)

            for (index, chunk) in ["alpha", "beta", "gamma"].enumerated() {
                let response = try await send(
                    "PUT", key: "big.bin",
                    query: [URLQueryItem(name: "partNumber", value: String(index + 1)),
                            URLQueryItem(name: "uploadId", value: uploadID)],
                    body: Data(chunk.utf8), on: server)
                #expect(response.status == 200)
            }

            let manifest = Data("""
                <CompleteMultipartUpload>\
                <Part><PartNumber>1</PartNumber></Part>\
                <Part><PartNumber>2</PartNumber></Part>\
                <Part><PartNumber>3</PartNumber></Part>\
                </CompleteMultipartUpload>
                """.utf8)
            let completed = try await send(
                "POST", key: "big.bin",
                query: [URLQueryItem(name: "uploadId", value: uploadID)],
                body: manifest, on: server)
            #expect(completed.status == 200)
            #expect(server.store.object(forKey: "big.bin")?.data == Data("alphabetagamma".utf8))
            #expect(server.store.openUploadCount == 0)
        }
    }

    @Test
    func abandonsAnAbortedUpload() async throws {
        try await withServer { server in
            let initiated = try await send(
                "POST", key: "big.bin", query: [URLQueryItem(name: "uploads", value: "")],
                on: server)
            let uploadID = try #require(
                S3Handler.values(ofElement: "uploadid", in: initiated.data).first)
            #expect(server.store.openUploadCount == 1)
            let aborted = try await send(
                "DELETE", key: "big.bin",
                query: [URLQueryItem(name: "uploadId", value: uploadID)], on: server)
            #expect(aborted.status == 204)
            #expect(server.store.openUploadCount == 0)
        }
    }

    @Test
    func canPretendToBeAReadOnlyKey() async throws {
        try await withServer(TestS3Server.Behaviour(forbidsWrites: true)) { server in
            server.store.put(Data("x".utf8), forKey: "a.txt")
            let read = try await send("GET", key: "a.txt", on: server)
            #expect(read.status == 200)
            let write = try await send("PUT", key: "b.txt", body: Data("y".utf8), on: server)
            #expect(write.status == 403)
            #expect(write.text.contains("AccessDenied"))
        }
    }
}
