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
import Observation

/// Tells a build that did not come from the App Store when a newer release
/// is published on GitHub.
///
/// App Store builds never ask: the App Store updates them, and an app it
/// distributes may not carry an updater of its own. Asking sends nothing but
/// the request for the latest release.
@MainActor
@Observable
final class UpdateChecker {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(GitHubRelease)
        case failed(String)
    }

    static let automaticChecksKey = "update.automaticChecks"
    private static let lastCheckKey = "update.lastCheck"
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    private(set) var state: State = .idle

    /// False until it is known the copy did not come from the App Store,
    /// which is asked once at launch.
    private(set) var isAvailable = false

    var lastChecked: Date? {
        UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
    }

    var checksAutomatically: Bool {
        get { UserDefaults.standard.object(forKey: Self.automaticChecksKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.automaticChecksKey) }
    }

    private var schedule: Task<Void, Never>?

    /// Checks once a day while automatic checks are on.
    func startAutomaticChecks() {
        guard schedule == nil else { return }
        schedule = Task { [weak self] in
            guard !(await AppInfo.isFromAppStore()) else { return }
            self?.isAvailable = true
            while !Task.isCancelled {
                guard let self else { return }
                let due = (self.lastChecked ?? .distantPast).addingTimeInterval(Self.checkInterval)
                if self.checksAutomatically, due <= Date() {
                    await self.check(announcing: true)
                }
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }

    /// - Parameter announcing: whether a newer release is worth a
    ///   notification. Not for a check the person started themselves, who is
    ///   looking at the answer already.
    func check(announcing: Bool = false) async {
        guard isAvailable, state != .checking else { return }
        state = .checking
        do {
            var request = URLRequest(url: GitHubRepository.latestReleaseAPIURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            let release = try GitHubRepository.latestRelease(
                from: data, statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            if let release, AppVersion.isNewer(release.version, than: AppInfo.version) {
                if announcing, state != .available(release) {
                    AppNotifier.updateAvailable(version: release.version)
                }
                state = .available(release)
            } else {
                state = .upToDate
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func download(_ release: GitHubRelease) {
        NSWorkspace.shared.open(release.downloadURL)
    }
}
