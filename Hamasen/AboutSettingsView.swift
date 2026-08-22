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

import AppKit
import HamasenCore
import SwiftUI

/// What this app is, where it comes from, and who wrote it.
struct AboutSettingsView: View {
    @State private var contributors: ContributorsState = .idle

    private enum ContributorsState {
        case idle
        case loading
        case loaded([GitHubContributor])
        case failed
    }

    var body: some View {
        Form {
            Section {
                identity
            }

            Section {
                LabeledContent("原始碼") {
                    Link(
                        "github.com/\(GitHubRepository.owner)/\(GitHubRepository.name)",
                        destination: GitHubRepository.webURL
                    )
                }
                LabeledContent("回報問題") {
                    Link("GitHub Issues", destination: GitHubRepository.issuesURL)
                }
                LabeledContent("授權") {
                    Link("Apache License 2.0", destination: GitHubRepository.licenseURL)
                }
            } header: {
                Text("專案")
            }

            Section {
                contributorsContent
            } header: {
                Text("貢獻者")
            } footer: {
                // Said plainly: this page is the only thing in the app that
                // talks to anywhere but your own servers.
                Text("這份名單在開啟這個頁面時向 GitHub 取得，是這個 App 唯一一處連往自家伺服器以外的地方。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .task { await loadContributors() }
    }

    // MARK: - Identity

    private var identity: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.applicationName)
                    .font(.headline)
                Text(Self.versionSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text("把遠端伺服器掛進 Finder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private static var applicationName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Hamasen"
    }

    /// Marketing version with the build behind it, which is what a bug report
    /// needs to name one build apart from another that shares its number.
    private static var versionSummary: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }

    // MARK: - Contributors

    @ViewBuilder
    private var contributorsContent: some View {
        switch contributors {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("讀取中…")
                    .foregroundStyle(.secondary)
            }
        case .loaded(let people) where people.isEmpty:
            Link("在 GitHub 上查看", destination: GitHubRepository.contributorsURL)
        case .loaded(let people):
            ForEach(people) { person in
                ContributorRow(contributor: person)
            }
        case .failed:
            // No error text: nobody opened this page to be told GitHub was
            // unreachable, and the link goes where the list would have.
            Link("在 GitHub 上查看", destination: GitHubRepository.contributorsURL)
        }
    }

    private func loadContributors() async {
        guard case .idle = contributors else { return }
        contributors = .loading
        do {
            let (data, _) = try await URLSession.shared.data(from: GitHubRepository.contributorsAPIURL)
            contributors = .loaded(try GitHubRepository.contributors(from: data))
        } catch {
            contributors = .failed
        }
    }
}

/// One person, with their avatar and how much of this they wrote.
private struct ContributorRow: View {
    let contributor: GitHubContributor

    var body: some View {
        HStack(spacing: 10) {
            AsyncImage(url: contributor.avatarURL) { image in
                image.resizable()
            } placeholder: {
                Circle().fill(.quaternary)
            }
            .frame(width: 28, height: 28)
            .clipShape(Circle())

            if let profileURL = contributor.profileURL {
                Link(contributor.login, destination: profileURL)
            } else {
                Text(contributor.login)
            }

            Spacer(minLength: 0)

            Text("\(contributor.contributions)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}
