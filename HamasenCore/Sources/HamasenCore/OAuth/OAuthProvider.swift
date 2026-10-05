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

import CryptoKit
import Foundation

/// A cloud drive's sign-in service: where the browser is sent, where the
/// code is exchanged, and what access is asked for.
///
/// Every provider here is used as a public client with PKCE and a loopback
/// redirect, which is what each of them documents for a desktop app: the
/// browser does the signing in, and the password never passes through
/// Hamasen.
public enum OAuthProvider: String, Codable, Sendable, CaseIterable {
    case google
    case microsoft
    case dropbox

    public var displayName: String {
        switch self {
        case .google: return "Google"
        case .microsoft: return "Microsoft"
        case .dropbox: return "Dropbox"
        }
    }

    public var authorizationURL: URL {
        switch self {
        case .google: return URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        case .microsoft: return URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!
        case .dropbox: return URL(string: "https://www.dropbox.com/oauth2/authorize")!
        }
    }

    public var tokenURL: URL {
        switch self {
        case .google: return URL(string: "https://oauth2.googleapis.com/token")!
        case .microsoft: return URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!
        case .dropbox: return URL(string: "https://api.dropboxapi.com/oauth2/token")!
        }
    }

    /// The access asked for: the whole drive, since a mount that can only see
    /// what this app created would be no mount at all, and a refresh token so
    /// the mount keeps working after the first hour.
    var scopes: [String] {
        switch self {
        case .google:
            return ["https://www.googleapis.com/auth/drive"]
        case .microsoft:
            return ["Files.ReadWrite.All", "User.Read", "offline_access"]
        case .dropbox:
            return [
                "account_info.read", "files.metadata.read", "files.metadata.write",
                "files.content.read", "files.content.write",
            ]
        }
    }

    /// Parameters each provider needs before it will issue a refresh token.
    var additionalAuthorizationParameters: [URLQueryItem] {
        switch self {
        case .google:
            // Without consent being asked again, a second sign-in with the
            // same account returns no refresh token.
            return [
                URLQueryItem(name: "access_type", value: "offline"),
                URLQueryItem(name: "prompt", value: "consent"),
            ]
        case .microsoft:
            return [URLQueryItem(name: "prompt", value: "select_account")]
        case .dropbox:
            return [URLQueryItem(name: "token_access_type", value: "offline")]
        }
    }

    /// The host stored as a cloud drive's `ServerConfig.host`: the API it
    /// talks to, so a configuration still names where its files are.
    public var apiHost: String {
        switch self {
        case .google: return "www.googleapis.com"
        case .microsoft: return "graph.microsoft.com"
        case .dropbox: return "api.dropboxapi.com"
        }
    }

    /// Dropbox matches a redirect address exactly, port included, so it is
    /// always sent to this one. The others accept any loopback port and use
    /// it too unless something else already has it.
    public static let preferredLoopbackPort: UInt16 = 53682

    public var requiresPreferredLoopbackPort: Bool { self == .dropbox }

    /// The redirect address each provider is registered with. Microsoft's
    /// registration names `localhost`; the others take the loopback address.
    public func redirectURI(port: UInt16) -> String {
        switch self {
        case .microsoft: return "http://localhost:\(port)/"
        case .google, .dropbox: return "http://127.0.0.1:\(port)/"
        }
    }

    /// Where the developer registers an app to get a client ID, for the
    /// settings that ask for one.
    public var developerConsoleURL: URL {
        switch self {
        case .google: return URL(string: "https://console.cloud.google.com/apis/credentials")!
        case .microsoft: return URL(string: "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade")!
        case .dropbox: return URL(string: "https://www.dropbox.com/developers/apps")!
        }
    }

    /// Google issues desktop clients a secret that its documentation says is
    /// not one, and still requires it at the token endpoint.
    public var usesClientSecret: Bool { self == .google }
}

/// The app identity a sign-in is made under.
///
/// Stored with every token, so a refresh always uses the client that issued
/// it — changing the client in Settings affects the next sign-in and never
/// strands the connections signed in before.
public struct OAuthClient: Codable, Sendable, Equatable {
    public let clientID: String
    public let clientSecret: String?

    public init(clientID: String, clientSecret: String? = nil) {
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientSecret = (secret?.isEmpty ?? true) ? nil : secret
    }

    /// The client configured for a provider: what the user entered in
    /// Settings, else what this build was registered with, else nothing —
    /// in which case signing in cannot start and Settings says why.
    public static func configured(
        for provider: OAuthProvider,
        in store: UserDefaults = AppSettings.sharedStore
    ) -> OAuthClient? {
        let keys = AppSettings.Keys.oauthClient(provider)
        let enteredID = store.string(forKey: keys.id)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !enteredID.isEmpty {
            return OAuthClient(clientID: enteredID, clientSecret: store.string(forKey: keys.secret))
        }
        return builtIn(for: provider)
    }

    /// The client this build was registered with, if any.
    public static func builtIn(for provider: OAuthProvider) -> OAuthClient? {
        OAuthBuiltInClients.client(for: provider)
    }
}

/// Clients this build was registered with, if any.
///
/// Empty in the source tree: a client ID ties sign-ins to whoever registered
/// it, and each distributor of Hamasen registers their own. Settings lets
/// anyone enter one instead.
enum OAuthBuiltInClients {
    static func client(for provider: OAuthProvider) -> OAuthClient? {
        let key: String
        switch provider {
        case .google: key = "HamasenGoogleClientID"
        case .microsoft: key = "HamasenMicrosoftClientID"
        case .dropbox: key = "HamasenDropboxClientID"
        }
        guard let clientID = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !clientID.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        let secret = Bundle.main.object(forInfoDictionaryKey: "HamasenGoogleClientSecret") as? String
        return OAuthClient(clientID: clientID, clientSecret: provider.usesClientSecret ? secret : nil)
    }
}

/// One sign-in attempt's PKCE pair and state, which the redirect has to echo.
public struct OAuthAuthorizationRequest: Sendable {
    public let provider: OAuthProvider
    public let client: OAuthClient
    public let redirectURI: String
    public let state: String
    public let codeVerifier: String

    public init(provider: OAuthProvider, client: OAuthClient, redirectURI: String) {
        self.provider = provider
        self.client = client
        self.redirectURI = redirectURI
        self.state = Self.randomURLSafeString(byteCount: 24)
        self.codeVerifier = Self.randomURLSafeString(byteCount: 48)
    }

    /// S256, the only method every provider here accepts.
    var codeChallenge: String {
        Self.base64URL(Data(SHA256.hash(data: Data(codeVerifier.utf8))))
    }

    /// The page the browser opens.
    public var url: URL {
        var components = URLComponents(url: provider.authorizationURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: client.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: provider.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ] + provider.additionalAuthorizationParameters
        return components.url!
    }

    /// Reads the authorization code out of the redirect, refusing one whose
    /// state is not this request's: anything on this Mac can open a loopback
    /// URL, and a code it planted would sign the connection in to its account.
    public func authorizationCode(fromRedirect url: URL) throws -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        if let error = value("error") {
            if error == "access_denied" { throw OAuthError.cancelled }
            throw OAuthError.providerRefused(value("error_description") ?? error)
        }
        guard value("state") == state else { throw OAuthError.stateMismatch }
        guard let code = value("code"), !code.isEmpty else {
            throw OAuthError.providerRefused("no authorization code")
        }
        return code
    }

    static func randomURLSafeString(byteCount: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public enum OAuthError: Error, Equatable, Sendable {
    /// The person closed the page or declined access.
    case cancelled
    /// The redirect did not carry the state this attempt sent.
    case stateMismatch
    /// No client ID has been configured for the provider.
    case clientNotConfigured(OAuthProvider)
    /// The provider answered with an error of its own.
    case providerRefused(String)
    /// The loopback address could not be listened on.
    case cannotListen(String)
}

extension OAuthError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return String(localized: "已取消登入", bundle: .module)
        case .stateMismatch:
            return String(localized: "登入回應與這次的要求不符，請重新登入", bundle: .module)
        case .clientNotConfigured(let provider):
            let name = provider.displayName
            return String(localized: "尚未設定 \(name) 的用戶端 ID，請到「設定 › 雲端服務」填寫", bundle: .module)
        case .providerRefused(let message):
            return String(localized: "登入失敗：\(message)", bundle: .module)
        case .cannotListen(let message):
            return String(localized: "無法接收登入結果：\(message)", bundle: .module)
        }
    }
}
