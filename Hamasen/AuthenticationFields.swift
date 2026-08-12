import HamasenCore
import SwiftUI

/// The authentication part of a server form, shared by the add sheet and the
/// detail pane so both offer the same choices and validation.
struct AuthenticationFields: View {
    @Binding var method: ServerConfig.AuthenticationMethod
    @Binding var password: String
    @Binding var importedKey: PrivateKeyImporter.ImportedKey?
    @Binding var keyPassphrase: String

    /// Whether a key is already stored, so the form can say so instead of
    /// asking for one again.
    let hasStoredKey: Bool
    /// Passwords may be left blank when editing an existing server.
    let allowsBlankPassword: Bool

    @State private var importError: String?

    var body: some View {
        Section("登入") {
            Picker("認證方式", selection: $method) {
                ForEach(ServerConfig.AuthenticationMethod.allCases, id: \.self) { method in
                    Text(method.displayName).tag(method)
                }
            }
            .pickerStyle(.segmented)

            switch method {
            case .password:
                SecureField(
                    "密碼",
                    text: $password,
                    prompt: allowsBlankPassword ? Text("留空表示不變更") : nil
                )
            case .privateKey:
                keyRow
                if importedKey?.info.isEncrypted ?? true {
                    SecureField(
                        "金鑰密碼",
                        text: $keyPassphrase,
                        prompt: Text(importedKey == nil ? "若金鑰有密碼保護" : "此金鑰需要密碼")
                    )
                }
                if let importError {
                    Text(importError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var keyRow: some View {
        LabeledContent("SSH 金鑰") {
            HStack(spacing: 8) {
                Text(keyStatusText)
                    .font(.callout)
                    .foregroundStyle(importedKey == nil && !hasStoredKey ? .secondary : .primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button("選擇金鑰檔…") {
                    importKey()
                }
            }
        }
    }

    private var keyStatusText: String {
        if let importedKey {
            return "\(importedKey.fileName)（\(importedKey.info.keyType.displayName)）"
        }
        return hasStoredKey ? "已儲存金鑰" : "尚未選擇"
    }

    private func importKey() {
        do {
            if let key = try PrivateKeyImporter.promptForKey() {
                importedKey = key
                importError = nil
            }
        } catch {
            importedKey = nil
            importError = error.localizedDescription
        }
    }
}
