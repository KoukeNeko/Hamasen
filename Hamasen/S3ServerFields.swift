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

/// What S3 calls things, and what it requires, in one place.
///
/// The add sheet and the detail pane both edit a server, and a field that
/// exists in only one of them is a setting the user can create and then never
/// see again.
enum S3ServerFields {
    static func accountLabel(
        for transferProtocol: ServerConfig.TransferProtocol
    ) -> LocalizedStringKey {
        transferProtocol == .s3 ? "Access Key ID" : "使用者名稱"
    }

    static func secretLabel(
        for transferProtocol: ServerConfig.TransferProtocol
    ) -> LocalizedStringKey {
        transferProtocol == .s3 ? "Secret Access Key" : "密碼"
    }

    static func remotePathPrompt(
        for transferProtocol: ServerConfig.TransferProtocol
    ) -> Text {
        Text(transferProtocol == .s3 ? "/bucket" : "/")
    }

    /// The first path component is the bucket, and S3 has nothing to connect
    /// to without one.
    ///
    /// Asked of the same parser the service uses, so a form cannot come to
    /// disagree with what will be accepted.
    static func namesABucket(
        _ remotePath: String, transferProtocol: ServerConfig.TransferProtocol
    ) -> Bool {
        guard transferProtocol == .s3 else { return true }
        let path = ServerConfig.normalizedRemotePath(remotePath)
        return (try? S3ObjectKey(absolutePath: path)) != nil
    }

    /// An empty field reads as one not filled in yet, the way an empty name
    /// does. A field with something in it that cannot work has to say so, or
    /// a disabled button is a dead end with no stated reason.
    static func remotePathIsUnusable(
        _ remotePath: String, transferProtocol: ServerConfig.TransferProtocol
    ) -> Bool {
        !remotePath.trimmingCharacters(in: .whitespaces).isEmpty
            && !namesABucket(remotePath, transferProtocol: transferProtocol)
    }
}

/// The two settings only S3 has, both of which exist to override a guess that
/// is right for every provider we know of.
struct S3OptionsSection: View {
    @Binding var region: String
    @Binding var addressingStyle: S3AddressingStyle

    var body: some View {
        Section("S3") {
            TextField("區域", text: $region, prompt: Text("自動判斷"))
            Picker("定址方式", selection: $addressingStyle) {
                ForEach(S3AddressingStyle.allCases, id: \.self) { style in
                    Text(style.displayName).tag(style)
                }
            }
        }
    }
}

/// Says what the remote path has to contain, and says it differently once
/// what is there cannot work.
struct S3RemotePathFooter: View {
    let remotePath: String
    let transferProtocol: ServerConfig.TransferProtocol

    var body: some View {
        if S3ServerFields.remotePathIsUnusable(remotePath, transferProtocol: transferProtocol) {
            Label(
                "遠端路徑要以 bucket 名稱開頭，例如 /my-bucket 或 /my-bucket/backups。",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            .labelStyle(.titleAndIcon)
            .fixedSize(horizontal: false, vertical: true)
        } else if transferProtocol == .s3 {
            Text("遠端路徑的第一段是 bucket 名稱，必填。後面可以再接一層前綴，例如 /my-bucket/backups。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
