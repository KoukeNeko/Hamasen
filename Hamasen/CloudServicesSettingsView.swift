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

import HamasenCore
import SwiftUI

/// The app registrations cloud drives sign in under.
///
/// Signing in to a cloud drive happens under an app registered with the
/// provider. A build can carry its own; where it does not — or where the
/// person would rather use theirs — the identifiers are entered here. They
/// are not secrets: each provider treats a desktop app's client as public.
struct CloudServicesSettingsView: View {
    var body: some View {
        Form {
            SettingsPaneHeader(pane: .cloud)
            Section {
                ForEach(CloudClientPage.services, id: \.provider) { service in
                    CloudServiceRow(service: service)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// One provider in the list, saying whether signing in can start.
private struct CloudServiceRow: View {
    let service: CloudClientPage.Service

    @AppStorage private var clientID: String

    init(service: CloudClientPage.Service) {
        self.service = service
        _clientID = AppStorage(
            wrappedValue: "", AppSettings.Keys.oauthClient(service.provider).id, store: AppSettings.sharedStore)
    }

    private var state: String {
        if !clientID.trimmingCharacters(in: .whitespaces).isEmpty { return String(localized: "已設定") }
        if OAuthClient.builtIn(for: service.provider) != nil { return String(localized: "內建") }
        return String(localized: "未設定")
    }

    var body: some View {
        SettingsNavigationRow(title: service.kind.title, value: state, page: .cloudClient(service.provider)) {
            ServiceIcon(kind: service.kind, size: 22)
        }
    }
}

/// The identifiers one provider's sign-in is made under.
struct CloudClientPage: View {
    struct Service {
        let provider: OAuthProvider
        let kind: ServiceKind
        let idLabel: LocalizedStringKey
        var secretLabel: LocalizedStringKey?
    }

    static let services = [
        Service(provider: .google, kind: .googleDrive, idLabel: "用戶端 ID", secretLabel: "用戶端密鑰"),
        Service(provider: .microsoft, kind: .oneDrive, idLabel: "應用程式 (用戶端) 識別碼"),
        Service(provider: .dropbox, kind: .dropbox, idLabel: "App Key"),
    ]

    let service: Service

    @AppStorage private var clientID: String
    @AppStorage private var clientSecret: String

    init(service: Service) {
        self.service = service
        let keys = AppSettings.Keys.oauthClient(service.provider)
        _clientID = AppStorage(wrappedValue: "", keys.id, store: AppSettings.sharedStore)
        _clientSecret = AppStorage(wrappedValue: "", keys.secret, store: AppSettings.sharedStore)
    }

    /// Whether this build was registered with the provider, so a blank field
    /// still works.
    private var hasBuiltInClient: Bool { OAuthClient.builtIn(for: service.provider) != nil }

    var body: some View {
        Form {
            SettingsPaneHeader(title: service.kind.title, summary: nil) {
                ServiceIcon(kind: service.kind, size: 64)
            }
            Section {
                TextField(service.idLabel, text: $clientID, prompt: hasBuiltInClient ? Text("使用內建") : Text("必填"))
                    .font(.body.monospaced())
                if let secretLabel = service.secretLabel {
                    SecureField(secretLabel, text: $clientSecret)
                }
            }
            Section {
                LabeledContent("重新導向 URI") {
                    Text(verbatim: service.provider.redirectURI(port: OAuthProvider.preferredLoopbackPort))
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
                Link(destination: service.provider.developerConsoleURL) {
                    Text("在 \(service.provider.displayName) 註冊應用程式")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(service.kind.title)
    }
}
