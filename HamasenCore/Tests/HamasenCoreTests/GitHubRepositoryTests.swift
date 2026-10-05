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

@Suite("GitHubRepository")
struct GitHubRepositoryTests {
    /// Shaped like the contributors endpoint, down to the field names, which
    /// are snake_case where the Swift side is not.
    private static let response = """
    [
      {
        "login": "octocat",
        "avatar_url": "https://avatars.githubusercontent.com/u/1",
        "html_url": "https://github.com/octocat",
        "contributions": 12
      },
      {
        "login": "dependabot[bot]",
        "avatar_url": "https://avatars.githubusercontent.com/u/2",
        "html_url": "https://github.com/apps/dependabot",
        "contributions": 99
      },
      {
        "login": "hubot",
        "avatar_url": "https://avatars.githubusercontent.com/u/3",
        "html_url": "https://github.com/hubot",
        "contributions": 40
      }
    ]
    """

    @Test("讀出登入名稱、頭像與貢獻數")
    func readsTheFields() throws {
        let contributors = try GitHubRepository.contributors(from: Data(Self.response.utf8))
        let first = try #require(contributors.first)

        #expect(first.login == "hubot")
        #expect(first.contributions == 40)
        #expect(first.avatarURL?.host() == "avatars.githubusercontent.com")
        #expect(first.profileURL?.absoluteString == "https://github.com/hubot")
    }

    /// A list of people should not open with a robot.
    @Test("略過機器人帳號")
    func dropsBots() throws {
        let contributors = try GitHubRepository.contributors(from: Data(Self.response.utf8))
        #expect(contributors.map(\.login) == ["hubot", "octocat"])
    }

    @Test("依貢獻數排序，不倚賴 API 的順序")
    func sortsByContributions() throws {
        let contributors = try GitHubRepository.contributors(from: Data(Self.response.utf8))
        #expect(contributors.map(\.contributions) == [40, 12])
    }

    @Test("回應不是預期格式時明確失敗")
    func failsOnSomethingElse() {
        #expect(throws: (any Error).self) {
            try GitHubRepository.contributors(from: Data(#"{"message":"Not Found"}"#.utf8))
        }
    }

    @Test("對外連結指向這個 repo")
    func pointsAtThisRepository() {
        #expect(GitHubRepository.webURL.absoluteString == "https://github.com/KoukeNeko/Hamasen")
        #expect(GitHubRepository.licenseURL.absoluteString.hasSuffix("/blob/main/LICENSE"))
        #expect(GitHubRepository.supportURL.absoluteString.hasSuffix("/blob/main/SUPPORT.md"))
        #expect(GitHubRepository.privacyPolicyURL.absoluteString.hasSuffix("/blob/main/PRIVACY.md"))
    }
}

@Suite("Update check")
struct UpdateCheckTests {
    @Test("版本逐段比較數字")
    func comparesVersions() {
        #expect(AppVersion.isNewer("1.10", than: "1.9"))
        #expect(!AppVersion.isNewer("1.2.0", than: "1.2"))
        #expect(AppVersion.isNewer("2.0", than: "1.99.9"))
        #expect(!AppVersion.isNewer("1.0", than: "1.0.1"))
        #expect(!AppVersion.isNewer("1.1-beta", than: "1.1"))
    }

    @Test("讀出最新版本與磁碟映像檔")
    func readsTheLatestRelease() throws {
        let json = """
        {"tag_name":"v1.2.0","html_url":"https://github.com/KoukeNeko/Hamasen/releases/tag/v1.2.0",
         "assets":[{"name":"Hamasen.zip","browser_download_url":"https://example.com/Hamasen.zip"},
                   {"name":"Hamasen.dmg","browser_download_url":"https://example.com/Hamasen.dmg"}]}
        """
        let release = try #require(try GitHubRepository.latestRelease(from: Data(json.utf8), statusCode: 200))
        #expect(release.version == "1.2.0")
        #expect(release.downloadURL == URL(string: "https://example.com/Hamasen.dmg"))
    }

    @Test("還沒有發布任何版本時不算錯誤")
    func noReleaseYetIsNotAnError() throws {
        // What GitHub answers for a repository with no published release.
        let notFound = Data(#"{"message":"Not Found","status":"404"}"#.utf8)
        #expect(try GitHubRepository.latestRelease(from: notFound, statusCode: 404) == nil)
        #expect(throws: URLError.self) {
            try GitHubRepository.latestRelease(from: Data(#"{"message":"API rate limit exceeded"}"#.utf8), statusCode: 403)
        }
    }
}
