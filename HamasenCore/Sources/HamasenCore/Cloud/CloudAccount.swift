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

/// Who a sign-in belongs to, asked of the provider it was made with.
public enum CloudAccount {
    /// The account's address, which names the connection and is what the
    /// person recognises their account by.
    public static func email(
        signedInWith token: OAuthToken, urlSession: URLSession? = nil
    ) async throws -> String {
        let credentials = ServerCredentials.oauth(token)
        // Not saved anywhere: the identifier only names a Keychain item a
        // renewal would be written to, and there is none for it.
        func config(_ transferProtocol: ServerConfig.TransferProtocol) -> ServerConfig {
            ServerConfig(
                name: "", transferProtocol: transferProtocol, host: token.provider.apiHost, port: 443,
                username: "", authenticationMethod: .oauth)
        }
        switch token.provider {
        case .dropbox:
            return try await DropboxFileService(
                config: config(.dropbox), credentials: credentials, urlSession: urlSession
            ).accountEmail()
        case .microsoft:
            return try await OneDriveFileService(
                config: config(.oneDrive), credentials: credentials, urlSession: urlSession
            ).accountEmail()
        case .google:
            return try await GoogleDriveFileService(
                config: config(.googleDrive), credentials: credentials, urlSession: urlSession
            ).accountEmail()
        }
    }
}
