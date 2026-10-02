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
    public static let supportURL = URL(string: "https://github.com/\(owner)/\(name)/blob/main/SUPPORT.md")!
    public static let privacyPolicyURL = URL(string: "https://github.com/\(owner)/\(name)/blob/main/PRIVACY.md")!
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

// MARK: - Releases

extension GitHubRepository {
    public static let releasesURL = URL(string: "https://github.com/\(owner)/\(name)/releases")!

    /// Asked only by builds that do not come from the App Store, which
    /// updates its own apps.
    public static let latestReleaseAPIURL = URL(
        string: "https://api.github.com/repos/\(owner)/\(name)/releases/latest"
    )!

    /// The release `latestReleaseAPIURL` answered with, or nil when none has
    /// been published: GitHub answers that with 404, and with nothing
    /// published, nothing is newer.
    public static func latestRelease(from data: Data, statusCode: Int) throws -> GitHubRelease? {
        switch statusCode {
        case 200: return try JSONDecoder().decode(GitHubRelease.self, from: data)
        case 404: return nil
        default: throw URLError(.badServerResponse)
        }
    }
}

/// A published release, as much of it as an update check needs.
public struct GitHubRelease: Equatable, Sendable, Decodable {
    public struct Asset: Equatable, Sendable, Decodable {
        public let name: String
        public let downloadURL: URL

        private enum CodingKeys: String, CodingKey {
            case name
            case downloadURL = "browser_download_url"
        }

        public init(name: String, downloadURL: URL) {
            self.name = name
            self.downloadURL = downloadURL
        }
    }

    public let tagName: String
    public let pageURL: URL
    public let assets: [Asset]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case pageURL = "html_url"
        case assets
    }

    public init(tagName: String, pageURL: URL, assets: [Asset]) {
        self.tagName = tagName
        self.pageURL = pageURL
        self.assets = assets
    }

    /// The version the tag names, without the "v" tags usually carry.
    public var version: String {
        tagName.hasPrefix("v") || tagName.hasPrefix("V") ? String(tagName.dropFirst()) : tagName
    }

    /// The disk image when there is one, which is what a person installs
    /// from; otherwise the release page.
    public var downloadURL: URL {
        assets.first { $0.name.lowercased().hasSuffix(".dmg") }?.downloadURL ?? pageURL
    }
}

public enum AppVersion {
    /// Whether `candidate` is a later version than `current`, comparing the
    /// dotted numbers one by one — "1.10" is after "1.9", and "1.2" equals
    /// "1.2.0". Anything after a "-" (a pre-release label) is ignored.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func numbers(_ version: String) -> [Int] {
            let core = version.split(separator: "-").first.map(String.init) ?? version
            return core.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        }
        let lhs = numbers(candidate)
        let rhs = numbers(current)
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }
}
