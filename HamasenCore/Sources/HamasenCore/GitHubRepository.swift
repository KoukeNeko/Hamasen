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

/// Where this app comes from, and who wrote it.
public enum GitHubRepository {
    public static let owner = "KoukeNeko"
    public static let name = "Hamasen"

    public static let webURL = URL(string: "https://github.com/\(owner)/\(name)")!
    public static let issuesURL = URL(string: "https://github.com/\(owner)/\(name)/issues")!
    public static let licenseURL = URL(string: "https://github.com/\(owner)/\(name)/blob/main/LICENSE")!
    public static let contributorsURL = URL(string: "https://github.com/\(owner)/\(name)/graphs/contributors")!

    /// The one address in this app that is not a server the user configured.
    public static let contributorsAPIURL = URL(
        string: "https://api.github.com/repos/\(owner)/\(name)/contributors"
    )!
}

/// One person who has committed to the repository.
public struct GitHubContributor: Equatable, Sendable, Identifiable, Decodable {
    public let login: String
    public let avatarURL: URL?
    public let profileURL: URL?
    public let contributions: Int

    public var id: String { login }

    private enum CodingKeys: String, CodingKey {
        case login
        case avatarURL = "avatar_url"
        case profileURL = "html_url"
        case contributions
    }

    public init(login: String, avatarURL: URL?, profileURL: URL?, contributions: Int) {
        self.login = login
        self.avatarURL = avatarURL
        self.profileURL = profileURL
        self.contributions = contributions
    }
}

extension GitHubContributor {
    /// Whether this is an automation rather than a person. GitHub marks them
    /// by name, and a list of people should not open with a robot.
    public var isBot: Bool {
        login.hasSuffix("[bot]")
    }
}

extension GitHubRepository {
    /// Reads the contributors endpoint.
    ///
    /// Bots are dropped and the rest are ordered by how much they wrote,
    /// which is the order the API already uses but not one it promises.
    public static func contributors(from data: Data) throws -> [GitHubContributor] {
        try JSONDecoder()
            .decode([GitHubContributor].self, from: data)
            .filter { !$0.isBot }
            .sorted { $0.contributions > $1.contributions }
    }
}
