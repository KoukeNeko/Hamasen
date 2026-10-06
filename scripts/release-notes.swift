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

// Checks the notes under ReleaseNotes/ and sends a version's App Store notes
// to App Store Connect.
//
//   swift scripts/release-notes.swift check [version]
//   swift scripts/release-notes.swift whats-new <version>
//
// whats-new reads ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (the .p8 file).
// A Swift script rather than shell because the API wants an ES256-signed
// token, which CryptoKit makes and the runner's shell tools do not.

import CryptoKit
import Foundation

let bundleID = "dev.hamasen.mac"
/// The App Store locales the app ships, as App Store Connect names them,
/// each one a file under appstore/.
let storeLocales = ["en-US", "ja", "ko", "zh-Hans", "zh-Hant"]
/// App Store Connect's limit on "What's New in This Version".
let whatsNewLimit = 4000

struct Failure: Error, CustomStringConvertible {
    let description: String
}

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("ReleaseNotes", isDirectory: true)

func directory(of version: String) -> URL {
    root.appendingPathComponent(version, isDirectory: true)
}

func read(_ url: URL) throws -> String {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        throw Failure(description: "missing \(url.path)")
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// The App Store notes of a version by locale, or nil when it has none: the
/// first version of an app has nothing to say it is new compared with.
func storeNotes(of version: String) throws -> [String: String]? {
    let folder = directory(of: version).appendingPathComponent("appstore", isDirectory: true)
    guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
    var notes: [String: String] = [:]
    for locale in storeLocales {
        notes[locale] = try read(folder.appendingPathComponent("\(locale).txt"))
    }
    let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }
    let unknown = Set(names).subtracting(storeLocales.map { "\($0).txt" })
    guard unknown.isEmpty else {
        throw Failure(description: "\(version)/appstore has files for no shipped locale: \(unknown.sorted())")
    }
    return notes
}

func check(_ version: String) throws {
    guard try !read(directory(of: version).appendingPathComponent("github.md")).isEmpty else {
        throw Failure(description: "\(version)/github.md is empty")
    }
    for (locale, text) in try storeNotes(of: version) ?? [:] {
        guard !text.isEmpty else { throw Failure(description: "\(version)/appstore/\(locale).txt is empty") }
        guard text.count <= whatsNewLimit else {
            throw Failure(description: "\(version)/appstore/\(locale).txt is \(text.count) characters; the limit is \(whatsNewLimit)")
        }
    }
}

// MARK: - App Store Connect

struct StoreConnect {
    let keyID: String
    let issuerID: String
    let key: P256.Signing.PrivateKey

    static func fromEnvironment() throws -> StoreConnect {
        let environment = ProcessInfo.processInfo.environment
        guard let keyID = environment["ASC_KEY_ID"], let issuerID = environment["ASC_ISSUER_ID"],
              let keyPath = environment["ASC_KEY_PATH"]
        else { throw Failure(description: "ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH must be set") }
        let pem = try String(contentsOfFile: keyPath, encoding: .utf8)
        return StoreConnect(keyID: keyID, issuerID: issuerID, key: try P256.Signing.PrivateKey(pemRepresentation: pem))
    }

    /// A token good for a few minutes; the API refuses one valid for more
    /// than twenty.
    func token() throws -> String {
        func encoded(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let now = Int(Date().timeIntervalSince1970)
        let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID, "typ": "JWT"])
        let claims = try JSONSerialization.data(withJSONObject: [
            "iss": issuerID, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1",
        ])
        let signed = encoded(header) + "." + encoded(claims)
        let signature = try key.signature(for: Data(signed.utf8))
        return signed + "." + encoded(signature.rawRepresentation)
    }

    func send(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://api.appstoreconnect.apple.com" + path)!)
        request.httpMethod = method
        request.setValue("Bearer \(try token())", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Failure(description: "\(method) \(path) answered \(status): \(String(decoding: data, as: UTF8.self))")
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    func list(_ path: String) async throws -> [[String: Any]] {
        try await send("GET", path)["data"] as? [[String: Any]] ?? []
    }
}

func encodedQuery(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
}

/// Writes each locale's notes into the version on App Store Connect,
/// making the version first when it is not there yet.
func uploadWhatsNew(_ version: String) async throws {
    guard let notes = try storeNotes(of: version) else {
        print("\(version) has no App Store notes; nothing to send")
        return
    }
    let store = try StoreConnect.fromEnvironment()

    guard let app = try await store.list("/v1/apps?filter[bundleId]=\(bundleID)").first,
          let appID = app["id"] as? String
    else { throw Failure(description: "no app with bundle ID \(bundleID)") }

    let versions = try await store.list(
        "/v1/apps/\(appID)/appStoreVersions?filter[platform]=MAC_OS&filter[versionString]=\(encodedQuery(version))")
    let versionID: String
    if let existing = versions.first?["id"] as? String {
        versionID = existing
    } else {
        let created = try await store.send("POST", "/v1/appStoreVersions", body: ["data": [
            "type": "appStoreVersions",
            "attributes": ["platform": "MAC_OS", "versionString": version],
            "relationships": ["app": ["data": ["type": "apps", "id": appID]]],
        ]])
        guard let id = (created["data"] as? [String: Any])?["id"] as? String else {
            throw Failure(description: "App Store Connect made version \(version) but named no ID")
        }
        versionID = id
        print("Created App Store version \(version)")
    }

    var existing: [String: String] = [:]
    for localization in try await store.list("/v1/appStoreVersions/\(versionID)/appStoreVersionLocalizations?limit=50") {
        if let id = localization["id"] as? String,
           let locale = (localization["attributes"] as? [String: Any])?["locale"] as? String {
            existing[locale] = id
        }
    }
    for locale in storeLocales {
        let text = notes[locale]!
        if let id = existing[locale] {
            _ = try await store.send("PATCH", "/v1/appStoreVersionLocalizations/\(id)", body: ["data": [
                "type": "appStoreVersionLocalizations", "id": id, "attributes": ["whatsNew": text],
            ]])
        } else {
            _ = try await store.send("POST", "/v1/appStoreVersionLocalizations", body: ["data": [
                "type": "appStoreVersionLocalizations",
                "attributes": ["locale": locale, "whatsNew": text],
                "relationships": ["appStoreVersion": ["data": ["type": "appStoreVersions", "id": versionID]]],
            ]])
        }
        print("What's New for \(locale) set on \(version)")
    }
}

// MARK: - Entry

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch (arguments.first, arguments.count) {
    case ("check", 1):
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for version in versions.sorted() where !version.hasPrefix(".") && version != "README.md" {
            try check(version)
        }
        print("Checked \(versions.filter { !$0.hasPrefix(".") && $0 != "README.md" }.count) versions")
    case ("check", 2):
        try check(arguments[1])
        print("\(arguments[1]) is ready")
    case ("whats-new", 2):
        try check(arguments[1])
        try await uploadWhatsNew(arguments[1])
    default:
        throw Failure(description: "usage: release-notes.swift check [version] | whats-new <version>")
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
