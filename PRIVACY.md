# Hamasen Privacy Policy

Effective date: August 23, 2026

[English](#english) · [繁體中文](#繁體中文) · [日本語](#日本語)

## English

Hamasen is a Mac app that connects directly to remote servers chosen and
configured by the user. This policy explains the information handled by the
app and by the developer.

### Summary

Hamasen does not require an account with the developer. The developer does not
operate a backend service that receives server configurations, credentials, or
remote file contents. The app contains no advertising, analytics, tracking, or
third-party crash-reporting SDK.

### Information handled on your Mac

Hamasen handles the following information to provide its features:

- **Server configuration:** server name, connection protocol, host, port,
  username, remote path, authentication method, and storage preferences. This
  is stored in the app's local App Group container.
- **Credentials:** passwords, SSH private keys, and key passphrases are stored
  in the macOS Keychain and used only to authenticate to servers you configure.
- **Remote files:** filenames, metadata, and file contents are transferred
  directly between your Mac and the configured server. macOS File Provider may
  keep local copies in its system-managed cache.
- **Connection safety information:** recorded SSH host-key fingerprints are
  stored locally so Hamasen can detect an unexpected server identity change.
- **Preferences and state:** mounted servers, pinned items, cache limits,
  language, and other app settings are stored locally.
- **Backups:** configuration backups are created only when you request them.
  Normal backups exclude credentials. A password-protected backup may include
  credentials and is saved to the location you choose.
- **Diagnostic logs:** Hamasen writes operational and error messages to the
  macOS unified log. These messages may include server addresses, usernames,
  remote paths, item identifiers, and error details. Passwords and private keys
  are not intentionally logged. Logs remain on your Mac unless you choose to
  share them.

The developer does not receive this information through the app.

### Network connections and third parties

Hamasen makes these network connections:

1. **Servers you configure.** Connection information, credentials, file
   metadata, and file contents are sent to those servers as required for the
   operations you request. Their handling is controlled by you and the server
   operator, not by the Hamasen developer. Plain FTP and plain WebDAV are not
   encrypted; Hamasen warns before those protocols are used.
2. **GitHub.** When you open the About page, Hamasen requests the repository's
   public contributor list and contributor avatars from GitHub. GitHub may
   receive ordinary network metadata such as your IP address and user agent.
   Hamasen does not send server configurations, credentials, filenames, or file
   contents to GitHub. GitHub handles requests under its
   [Privacy Statement](https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement).
3. **Apple and macOS.** Apple may process App Store, crash, or diagnostic data
   according to your system settings and Apple's policies. Hamasen does not add
   its own analytics or tracking to that system processing.

Hamasen does not sell personal information or share it with advertising or
analytics providers.

### Support communications

If you email the developer or open a GitHub issue, the developer receives the
information you voluntarily provide, such as your email address or GitHub
username, message, screenshots, and diagnostic details. This information is
used only to answer the request, investigate the problem, and improve Hamasen.
Do not send passwords, private keys, or server credentials.

### Retention, deletion, and privacy choices

- Deleting a server in Hamasen removes its saved configuration and credentials
  from the app and Keychain. Remove configured servers before uninstalling the
  app if you want their Keychain items deleted by Hamasen.
- File Provider caches are managed by macOS. You can use Hamasen's free-space
  action, unmount a server, or remove the server to stop using its local cache.
- Backups are files under your control and must be deleted from their chosen
  locations separately.
- macOS retains unified logs according to its own retention policy. Leave debug
  logging disabled unless you need it, and review logs before sharing them.
- Avoid opening the About page if you do not want the contributor request sent
  to GitHub.
- Support emails and issue content are retained only as long as reasonably
  needed to respond, maintain an issue history, and meet legal obligations. You
  may request deletion by emailing
  [develop@doeshing.uk](mailto:develop@doeshing.uk). Public GitHub issues may
  also be edited or deleted using GitHub's controls, subject to GitHub's policy.

Deleting local Hamasen data does not delete files or account information held
by a remote server operator, GitHub, or Apple. Contact those providers for data
they control.

### Security

Hamasen uses the macOS Keychain, App Sandbox, and File Provider architecture to
protect locally handled information. Password-protected backups are encrypted.
No method of storage or transmission is guaranteed to be completely secure.
Use encrypted connection protocols such as SFTP, FTPS, or WebDAV over HTTPS
when possible.

### Children's privacy

Hamasen is a general-purpose server utility and is not directed to children.
The developer does not knowingly collect personal information from children
through the app.

### Changes to this policy

This policy may be updated when Hamasen's data practices change. The effective
date above will be updated, and the repository history will retain prior
versions.

### Contact

Questions or deletion requests: [develop@doeshing.uk](mailto:develop@doeshing.uk)

## 繁體中文

Hamasen 是一款 Mac App，會直接連線至使用者自行選擇及設定的遠端伺服器。本政策說明 App 與開發者如何處理資訊。

### 摘要

Hamasen 不要求使用者向開發者註冊帳號。開發者沒有營運會接收伺服器設定、登入憑證或遠端檔案內容的後端服務。App 不含廣告、分析、追蹤或第三方當機回報 SDK。

### 在 Mac 上處理的資訊

Hamasen 為了提供功能，會在本機處理以下資訊：

- **伺服器設定：**伺服器名稱、連線協定、主機、連接埠、使用者名稱、遠端路徑、驗證方式與儲存偏好。這些資料儲存在 App 的本機 App Group 容器。
- **登入憑證：**密碼、SSH 私鑰與金鑰密碼儲存在 macOS 鑰匙圈，只用於向使用者設定的伺服器進行驗證。
- **遠端檔案：**檔名、中繼資料及檔案內容直接在 Mac 與設定的伺服器之間傳輸。macOS File Provider 可能在系統管理的快取中保存本機副本。
- **連線安全資訊：**已記錄的 SSH 主機金鑰指紋儲存在本機，讓 Hamasen 能偵測伺服器身分是否意外變更。
- **偏好與狀態：**已掛載的伺服器、釘選項目、快取限制、語言及其他 App 設定都儲存在本機。
- **備份：**只有在使用者主動要求時才會建立設定備份。一般備份不含登入憑證；含密碼的備份可能包含登入憑證，並儲存在使用者選擇的位置。
- **診斷紀錄：**Hamasen 會把運作與錯誤訊息寫入 macOS 統一紀錄。內容可能包含伺服器位址、使用者名稱、遠端路徑、項目識別碼及錯誤詳情。App 不會刻意記錄密碼或私鑰。除非使用者主動分享，紀錄會留在 Mac 上。

開發者不會透過 App 收到上述資訊。

### 網路連線與第三方

Hamasen 會建立以下網路連線：

1. **使用者設定的伺服器。**連線資訊、登入憑證、檔案中繼資料及內容會依照使用者要求的操作傳送至該伺服器。其資料處理由使用者與伺服器營運者控制，而非 Hamasen 開發者。未加密的 FTP 與 WebDAV 會以明文傳輸，Hamasen 會在使用前提出警告。
2. **GitHub。**開啟「關於」頁面時，Hamasen 會向 GitHub 取得公開的專案貢獻者清單與頭像。GitHub 可能收到 IP 位址、User-Agent 等一般網路中繼資料。Hamasen 不會向 GitHub 傳送伺服器設定、登入憑證、檔名或檔案內容。GitHub 依其[隱私權聲明](https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement)處理請求。
3. **Apple 與 macOS。**Apple 可能依照系統設定及其政策處理 App Store、當機或診斷資料。Hamasen 不會在這些系統機制之外加入自己的分析或追蹤功能。

Hamasen 不會出售個人資訊，也不會將個人資訊分享給廣告或分析服務商。

### 支援聯絡

如果使用者寄信給開發者或建立 GitHub Issue，開發者會收到使用者主動提供的資訊，例如 Email 地址或 GitHub 使用者名稱、訊息、截圖與診斷詳情。這些資訊只用於回覆請求、調查問題及改進 Hamasen。請勿傳送密碼、私鑰或伺服器登入憑證。

### 保存、刪除與隱私選擇

- 在 Hamasen 中刪除伺服器，會移除其已儲存的設定與鑰匙圈憑證。如果希望由 Hamasen 刪除鑰匙圈項目，請在解除安裝 App 前先刪除所有已設定的伺服器。
- File Provider 快取由 macOS 管理。使用者可使用 Hamasen 的釋放空間功能、卸載或刪除伺服器，以停止使用相關本機快取。
- 備份檔由使用者自行控制，必須另外從所選位置刪除。
- macOS 會依照自身政策保存統一紀錄。除非需要診斷，請保持偵錯紀錄關閉，並在分享前檢查紀錄內容。
- 如果不希望向 GitHub 發出貢獻者資料請求，請不要開啟「關於」頁面。
- 支援信件與 Issue 內容只在回覆、保留問題處理紀錄及符合法律義務所需的合理期間內保存。使用者可寄信至 [develop@doeshing.uk](mailto:develop@doeshing.uk) 要求刪除。公開 GitHub Issue 也可使用 GitHub 提供的控制功能編輯或刪除，並受 GitHub 政策約束。

刪除 Hamasen 本機資料不會刪除遠端伺服器營運者、GitHub 或 Apple 持有的檔案或帳號資訊；這些資料需向相應服務提供者提出要求。

### 安全性

Hamasen 使用 macOS 鑰匙圈、App Sandbox 與 File Provider 架構保護在本機處理的資訊。含密碼的備份會經過加密。任何儲存或傳輸方式都無法保證絕對安全；建議盡可能使用 SFTP、FTPS 或 HTTPS WebDAV 等加密連線協定。

### 兒童隱私

Hamasen 是一般用途的伺服器工具，並非針對兒童設計。開發者不會透過 App 刻意蒐集兒童的個人資訊。

### 政策變更

若 Hamasen 的資料處理方式改變，本政策可能會更新。上方生效日期會同步更新，舊版本則保留於儲存庫歷史紀錄中。

### 聯絡方式

隱私問題或刪除要求：[develop@doeshing.uk](mailto:develop@doeshing.uk)

## 日本語

Hamasenは、ユーザが選択して設定したリモートサーバに直接接続するMacアプリです。本ポリシーでは、アプリと開発者が取り扱う情報について説明します。

### 概要

Hamasenを利用するために、開発者のアカウントを作成する必要はありません。開発者は、サーバ設定、認証情報、リモートファイルの内容を受信するバックエンドサービスを運営していません。アプリには、広告、アクセス解析、トラッキング、または第三者のクラッシュ報告SDKは含まれていません。

### Mac上で取り扱う情報

Hamasenは機能を提供するため、次の情報をMac上で取り扱います。

- **サーバ設定：**サーバ名、接続プロトコル、ホスト、ポート、ユーザ名、リモートパス、認証方式、ストレージ設定。これらはアプリのローカルApp Groupコンテナに保存されます。
- **認証情報：**パスワード、SSH秘密鍵、鍵のパスフレーズはmacOSキーチェーンに保存され、ユーザが設定したサーバへの認証にのみ使用されます。
- **リモートファイル：**ファイル名、メタデータ、ファイル内容はMacと設定済みサーバの間で直接転送されます。macOS File Providerが、システム管理のキャッシュにローカルコピーを保存する場合があります。
- **接続の安全情報：**記録したSSHホスト鍵のフィンガープリントはMac上に保存され、サーバの識別情報が予期せず変わった場合の検出に使用されます。
- **設定と状態：**マウント済みサーバ、固定した項目、キャッシュ上限、言語、その他のアプリ設定はMac上に保存されます。
- **バックアップ：**設定バックアップは、ユーザが要求した場合にのみ作成されます。通常のバックアップには認証情報が含まれません。パスワードで保護されたバックアップには認証情報が含まれる場合があり、ユーザが選択した場所に保存されます。
- **診断ログ：**Hamasenは動作情報とエラーをmacOS統合ログに記録します。ログには、サーバアドレス、ユーザ名、リモートパス、項目識別子、エラーの詳細が含まれる場合があります。パスワードや秘密鍵を意図的に記録することはありません。ユーザが共有しない限り、ログはMac上に残ります。

開発者がアプリを通じてこれらの情報を受信することはありません。

### ネットワーク接続と第三者

Hamasenは次のネットワーク接続を行います。

1. **ユーザが設定したサーバ。**ユーザが要求した操作に必要な接続情報、認証情報、ファイルのメタデータ、ファイル内容が送信されます。これらの取り扱いはユーザとサーバ運営者が管理するもので、Hamasen開発者は管理しません。暗号化されていないFTPとWebDAVでは情報が平文で送信されるため、Hamasenは使用前に警告を表示します。
2. **GitHub。**「このアプリについて」画面を開くと、Hamasenは公開されているリポジトリのコントリビュータ一覧とアバターをGitHubから取得します。GitHubは、IPアドレスやUser-Agentなどの通常のネットワークメタデータを受信する場合があります。Hamasenがサーバ設定、認証情報、ファイル名、ファイル内容をGitHubへ送信することはありません。GitHubは[プライバシーステートメント](https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement)に従ってリクエストを処理します。
3. **AppleとmacOS。**Appleは、システム設定とAppleのポリシーに従って、App Store、クラッシュ、診断に関するデータを処理する場合があります。Hamasenは、このシステム処理とは別に独自の解析やトラッキングを追加しません。

Hamasenは個人情報を販売せず、広告事業者や解析事業者と共有しません。

### サポートへの連絡

開発者へのメールまたはGitHub Issueには、ユーザが自ら提供したメールアドレスまたはGitHubユーザ名、メッセージ、スクリーンショット、診断情報が含まれる場合があります。これらは、問い合わせへの回答、問題の調査、Hamasenの改善にのみ使用されます。パスワード、秘密鍵、サーバの認証情報を送信しないでください。

### 保存、削除、プライバシーの選択

- Hamasenでサーバを削除すると、保存済みの設定とキーチェーンの認証情報が削除されます。Hamasenによるキーチェーン項目の削除を希望する場合は、アプリをアンインストールする前に設定済みの各サーバを削除してください。
- File ProviderのキャッシュはmacOSが管理します。Hamasenの空き領域確保操作を使用するか、サーバを取り出す、または削除することで、関連するローカルキャッシュの使用を停止できます。
- バックアップファイルはユーザが管理するため、保存先から別途削除する必要があります。
- macOSは独自の保持方針に従って統合ログを保存します。診断に必要な場合を除きデバッグログを無効にし、共有する前に内容を確認してください。
- GitHubへのコントリビュータ情報リクエストを望まない場合は、「このアプリについて」画面を開かないでください。
- サポートメールとIssueの内容は、回答、問題履歴の維持、法的義務の履行に合理的に必要な期間のみ保持されます。削除を希望する場合は[develop@doeshing.uk](mailto:develop@doeshing.uk)へ連絡してください。公開GitHub IssueはGitHubの機能を使って編集または削除できますが、GitHubのポリシーが適用されます。

Hamasenのローカルデータを削除しても、リモートサーバ運営者、GitHub、Appleが保持するファイルやアカウント情報は削除されません。それぞれの事業者へお問い合わせください。

### セキュリティ

Hamasenは、macOSキーチェーン、App Sandbox、File Providerアーキテクチャを使用してMac上の情報を保護します。パスワードで保護されたバックアップは暗号化されます。ただし、保存や通信の安全性を完全に保証することはできません。可能な限りSFTP、FTPS、HTTPSのWebDAVなど、暗号化された接続プロトコルを使用してください。

### 子どものプライバシー

Hamasenは一般用途のサーバユーティリティであり、子どもを対象としたものではありません。開発者がアプリを通じて子どもの個人情報を意図的に収集することはありません。

### 本ポリシーの変更

Hamasenのデータ取り扱い方法が変わった場合、本ポリシーを更新することがあります。上記の発効日を更新し、以前の版はリポジトリの履歴に保持します。

### 連絡先

プライバシーに関する質問または削除依頼：[develop@doeshing.uk](mailto:develop@doeshing.uk)
