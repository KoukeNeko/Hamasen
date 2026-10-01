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
                LabeledContent("支援") {
                    Link(destination: GitHubRepository.supportURL) {
                        Text(verbatim: "SUPPORT.md")
                    }
                }
                LabeledContent("隱私權政策") {
                    Link(destination: GitHubRepository.privacyPolicyURL) {
                        Text(verbatim: "PRIVACY.md")
                    }
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
            }

            Section {
                Text("Google 雲端硬碟是 Google LLC 的商標。OneDrive 是 Microsoft 集團的商標。Dropbox 是 Dropbox, Inc. 的商標。其他名稱為各自所有者的商標。\(AppInfo.displayName) 與上述公司無關，也未獲其背書。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent("服務標誌") {
                    Link(destination: URL(string: "https://thesvg.org")!) {
                        Text(verbatim: "thesvg.org")
                    }
                }
            } header: {
                Text("商標")
            }
        }
        .formStyle(.grouped)
        .task { await loadContributors() }
    }

    // MARK: - Identity

    /// The app as About This Mac presents the Mac: its icon, its name, its
    /// version, centred at the top.
    private var identity: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)
            Text(AppInfo.displayName)
                .font(.title2.bold())
            Text("把 NAS、伺服器和雲端硬碟放進 Finder")
                .foregroundStyle(.secondary)
            Text(Self.versionSummary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    /// Marketing version with the build behind it, which is what a bug report
    /// needs to name one build apart from another that shares its number.
    private static var versionSummary: String {
        "\(AppInfo.version) (\(AppInfo.build))"
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
