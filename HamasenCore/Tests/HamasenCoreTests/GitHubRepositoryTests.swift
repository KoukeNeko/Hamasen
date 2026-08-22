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
    }
}
