# Server Path

把遠端 SFTP 伺服器像 CloudStorage（iCloud Drive / OneDrive）一樣掛載到 Finder 側邊欄的 macOS App。

基於 Apple 官方的 **File Provider（`NSFileProviderReplicatedExtension`）** 機制 — 不需要 macFUSE、不需要核心擴充，可上 App Store。

## 架構

```
Server Path.xcodeproj
├── Server Path（主 App，SwiftUI）
│   └── 伺服器清單、新增/編輯連線、掛載/卸載（NSFileProviderManager）
├── ServerPathFileProvider（File Provider Extension）
│   └── NSFileProviderReplicatedExtension：enumerate / fetch / create / modify / delete
├── ServerPathCore（本地 Swift Package）
│   ├── RemoteFileService  — 協定抽象層（SFTP 之外未來可插入 FTP）
│   ├── SFTPFileService    — Citadel（SwiftNIO SSH）實作
│   ├── ServerConfigStore  — 設定檔（App Group 容器內的 JSON）
│   └── KeychainCredentialStore — 密碼只進 Keychain（Data Protection + App Group 共享）
└── Config/ — entitlements 與 extension Info.plist
```

- App 與 Extension 透過 **App Group**（`group.dev.serverpath.shared`）共享伺服器設定與 Keychain 憑證。
- **單一 File Provider domain**：Finder 側邊欄只有一個「Server Path」，
  點進去後每台已掛載的伺服器是一個以伺服器命名的資料夾。
- 掛載狀態存於 `MountedServersStore`（App Group 內 JSON）；掛載/卸載/改名
  透過 sync anchor 變化即時反映到 Finder。

## 開發

需求：Xcode 26+（目前以 Xcode 27 beta 驗證）、Apple Development 簽章憑證。

```bash
# 跑完整驗證（套件測試 + App/Extension 建置）
./scripts/verify.sh
```

測試不需要外部伺服器：`ServerPathCoreTests` 內建 in-process SFTP 伺服器
（Citadel server + 本機暫存目錄），16 個測試涵蓋連線、認證、列目錄、
上傳下載、建立/刪除/改名與 remotePath 基準目錄。

## 手動驗證掛載（Finder 端到端）

1. 用 Xcode 開啟專案，執行「Server Path」scheme（⌘R）。
2. 在 App 中新增一台 SFTP 伺服器（主機、帳號、密碼）。
3. 按「掛載」— 伺服器會出現在 Finder 側邊欄「位置」區。
4. 掛載內容實際位於 `~/Library/CloudStorage/`。

## 目前狀態（Phase 1 MVP）

- [x] SFTP 連線（密碼認證）
- [x] Finder 掛載：瀏覽、下載（點開檔案）、上傳、新增資料夾、改名、移動、刪除
- [ ] Phase 2：FTP/FTPS、SSH 金鑰認證、host key 驗證（TOFU）、大檔串流、變更追蹤（sync anchor）

已知限制：
- 檔案上傳/下載目前整檔進記憶體，超大檔案（GB 級）會吃記憶體，Phase 2 改串流。
- Host key 目前不驗證（`acceptAnything`），Phase 2 加入 TOFU pinning。
- 遠端變更不會主動推播到 Finder（重新整理時全量列舉）。
