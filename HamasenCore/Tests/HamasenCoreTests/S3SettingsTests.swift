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

@Suite("S3 settings")
struct S3SettingsTests {
    // MARK: - Server configuration

    @Test
    func theNewFieldsSurviveARoundTrip() throws {
        let original = ServerConfig(
            name: "R2", transferProtocol: .s3, host: "abc.r2.cloudflarestorage.com",
            port: 443, username: "AKIA", remotePath: "/bucket/data",
            s3Region: "auto", s3AddressingStyle: .path)
        let decoded = try JSONDecoder().decode(
            ServerConfig.self, from: JSONEncoder().encode(original))
        #expect(decoded.s3Region == "auto")
        #expect(decoded.s3AddressingStyle == .path)
    }

    /// A server saved before S3 existed has neither field, and must still
    /// open. The absent values are the ones that mean "work it out".
    @Test
    func aServerSavedBeforeS3StillDecodes() throws {
        let json = Data("""
            {"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","name":"舊的 SFTP",
             "transferProtocol":"sftp","host":"example.com","port":22,
             "username":"me","remotePath":"/home/me"}
            """.utf8)
        let decoded = try JSONDecoder().decode(ServerConfig.self, from: json)
        #expect(decoded.s3Region == nil)
        #expect(decoded.s3AddressingStyle == .automatic)
    }

    // MARK: - Endpoint derivation

    private func endpoint(
        host: String, region: String? = nil, style: S3AddressingStyle = .automatic, port: Int = 443
    ) -> S3Endpoint {
        RemoteFileServiceFactory.s3Endpoint(for: ServerConfig(
            name: "s", transferProtocol: .s3, host: host, port: port,
            username: "AKIA", remotePath: "/bucket",
            s3Region: region, s3AddressingStyle: style))
    }

    @Test
    func anUnsetRegionIsReadOutOfTheHostname() {
        #expect(endpoint(host: "s3.eu-west-2.amazonaws.com").region == "eu-west-2")
        #expect(endpoint(host: "abc.r2.cloudflarestorage.com").region == "auto")
    }

    /// The stored value exists for the provider the guess does not fit.
    @Test
    func aStoredRegionOverridesTheGuess() {
        #expect(endpoint(host: "s3.eu-west-2.amazonaws.com", region: "us-east-1").region
            == "us-east-1")
        #expect(endpoint(host: "storage.example.com", region: "eu-central-1").region
            == "eu-central-1")
    }

    /// An empty string is what a cleared text field leaves behind, and it is
    /// not a region.
    @Test
    func anEmptyRegionFallsBackToTheGuess() {
        #expect(endpoint(host: "s3.ap-northeast-1.amazonaws.com", region: "").region
            == "ap-northeast-1")
    }

    @Test
    func theDefaultPortIsLeftOutOfTheEndpoint() {
        #expect(endpoint(host: "abc.r2.cloudflarestorage.com", port: 443).port == nil)
        #expect(endpoint(host: "minio.example.com", port: 9000).port == 9000)
    }

    @Test
    func theStoredAddressingStyleIsCarriedThrough() {
        #expect(endpoint(host: "s3.amazonaws.com", style: .path)
            .resolvedStyle(for: "bucket") == .path)
        #expect(endpoint(host: "abc.r2.cloudflarestorage.com", style: .virtualHosted)
            .resolvedStyle(for: "bucket") == .virtualHosted)
    }

    // MARK: - Multipart settings

    private func store() -> UserDefaults {
        let suite = "dev.hamasen.tests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite) ?? .standard
    }

    @Test
    func unsetSizesFallBackToTheDefaults() {
        let defaults = store()
        #expect(AppSettings.s3PartSizeBytes(from: defaults)
            == AppSettings.defaultS3PartSizeBytes)
        #expect(AppSettings.s3MultipartThresholdBytes(from: defaults)
            == AppSettings.defaultS3MultipartThresholdBytes)
    }

    /// S3 refuses a part below 5 MiB except the last one, so a value under
    /// that would make every large upload fail.
    @Test
    func aPartSizeOutsideS3sOwnBoundsIsIgnored() {
        let defaults = store()
        defaults.set(1024, forKey: AppSettings.Keys.s3PartSizeBytes)
        #expect(AppSettings.s3PartSizeBytes(from: defaults)
            == AppSettings.defaultS3PartSizeBytes)

        defaults.set(64 * 1024 * 1024 * 1024, forKey: AppSettings.Keys.s3PartSizeBytes)
        #expect(AppSettings.s3PartSizeBytes(from: defaults)
            == AppSettings.defaultS3PartSizeBytes)
    }

    @Test
    func aPartSizeInsideTheBoundsIsUsed() {
        let defaults = store()
        defaults.set(32 * 1024 * 1024, forKey: AppSettings.Keys.s3PartSizeBytes)
        #expect(AppSettings.s3PartSizeBytes(from: defaults) == 32 * 1024 * 1024)
    }

    /// A threshold below one part would send a single-part multipart upload:
    /// three requests where one would do.
    @Test
    func theThresholdIsNeverBelowThePartSize() {
        let defaults = store()
        defaults.set(64 * 1024 * 1024, forKey: AppSettings.Keys.s3PartSizeBytes)
        defaults.set(8 * 1024 * 1024, forKey: AppSettings.Keys.s3MultipartThresholdBytes)
        #expect(AppSettings.s3MultipartThresholdBytes(from: defaults) == 64 * 1024 * 1024)
    }

    // MARK: - What Settings offers

    /// Every preset has to be inside the range the getter accepts, or the
    /// picker would offer a value that is silently replaced on read.
    @Test
    func everyPresetIsAValueTheSettingWillKeep() {
        for size in S3PartSize.allCases {
            #expect(AppSettings.s3PartSizeRange.contains(size.rawValue),
                    "\(size.displayName) is outside the accepted range")
        }
        for threshold in S3MultipartThreshold.allCases {
            #expect(AppSettings.s3MultipartThresholdRange.contains(threshold.rawValue),
                    "\(threshold.displayName) is outside the accepted range")
        }
    }

    /// A stored value from an older build, or one hand-edited in defaults,
    /// is not one of the presets. The picker still has to show something.
    @Test
    func anUnrecognisedStoredSizeFallsBackToTheDefault() {
        #expect(S3PartSize(bytes: 12_345).rawValue == AppSettings.defaultS3PartSizeBytes)
        #expect(S3MultipartThreshold(bytes: 12_345).rawValue
            == AppSettings.defaultS3MultipartThresholdBytes)
    }

    @Test
    func aRecognisedStoredSizeIsShownAsItself() {
        #expect(S3PartSize(bytes: 67_108_864) == .sixtyFourMebibytes)
        #expect(S3MultipartThreshold(bytes: 1_073_741_824) == .oneGibibyte)
    }

    /// Shrinking the part size lowers the largest file that can be uploaded
    /// at all, which is why the setting has to show the product.
    @Test
    func theUploadCeilingFollowsThePartSize() {
        let mebibyte = 1024 * 1024
        #expect(AppSettings.s3LargestUploadableBytes(partSizeBytes: 5 * mebibyte)
            == 50_000 * mebibyte)
        #expect(AppSettings.s3LargestUploadableBytes(
            partSizeBytes: AppSettings.defaultS3PartSizeBytes) == 160_000 * mebibyte)
    }
}
