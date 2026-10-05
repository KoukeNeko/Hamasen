<p align="center">
  <img src="Docs/app-icon.png" alt="Hamasen" width="160">
</p>

<h1 align="center">Hamasen 哈瑪星</h1>

<p align="center">
  <strong>Your servers, docked in Finder.</strong><br>
  Mount SFTP, FTP, WebDAV, SMB, S3-compatible storage, Google Drive,
  OneDrive and Dropbox as native Finder locations — browse, open, edit and
  drag files without a separate client window.
</p>

<p align="center">
  <img alt="macOS 15.6+" src="https://img.shields.io/badge/MACOS-15.6%2B-000000?style=for-the-badge&logo=apple&logoColor=white">
  <img alt="Swift 6.0" src="https://img.shields.io/badge/SWIFT-6.0-F05138?style=for-the-badge&logo=swift&logoColor=white">
  <a href="https://developer.apple.com/documentation/fileprovider"><img alt="File Provider" src="https://img.shields.io/badge/FILE_PROVIDER-NO_KEXTS-4CAF50?style=for-the-badge&logo=apple&logoColor=white"></a>
  <a href="https://github.com/KoukeNeko/Hamasen/stargazers"><img alt="Stars" src="https://img.shields.io/github/stars/KoukeNeko/Hamasen?style=for-the-badge&logo=github&label=STARS&color=2196F3"></a>
</p>

<p align="center">
  <a href="#getting-started"><strong>Getting started</strong></a>
  · <a href="#see-it-in-action">See it in action</a>
  · <a href="#compatibility">Compatibility</a>
  · <a href="#technical-reference">Technical reference</a>
</p>

Hamasen puts a remote server in the Finder sidebar, where iCloud Drive and
OneDrive already live. Files open in the apps you already use, save straight
back, and drag between servers and the Desktop like anything else.

It is built on Apple's own **File Provider** framework — no macFUSE, no kernel
extension, and nothing to switch on in System Settings. What stays on this Mac
is your decision, credentials never leave the Keychain, and a server that
changes its identity is refused rather than trusted quietly.

## See it in action

<p align="center">
  <img src="Docs/en_home.png" width="85%" alt="The server list, with a mounted SFTP server">
</p>

## Every server, in one Finder location

Finder shows a single **Hamasen** location. Each mounted server is a folder
inside it, named whatever you named it:

```
Finder sidebar
└── Hamasen
    ├── Production NAS/     ← one folder per mounted server
    │   └── upload/ …          (live server content)
    └── Staging VPS/
```

Mounting and unmounting happen in the app; the folders appear and disappear in
Finder as you do it. Drag the list into whatever order suits you.

### Make each folder recognisable

Click a connection's icon at the top of its page to give its Finder folder a
look of its own: one of Finder's tag colors, a symbol, an emoji, or a picture
of your choosing. The name beside the icon is edited in place and names both
the connection and its folder. Colors, symbols and emoji are what Finder's own
**Customize Folder** sets on a local folder; a picture is kept on this Mac only,
never uploaded to the server, and put back if the folder is rebuilt.

A connection can also be **paused**: its folder stays in Finder, marked as
paused, and nothing is sent to the server until it is resumed — for a laptop on
a metered network, or a server under maintenance.

## Sign in to cloud drives in the browser

Google Drive, OneDrive and Dropbox are added by signing in on the provider's own
page in your browser. Hamasen never sees the password: it receives a token,
keeps it in the Keychain, and renews it as it expires. If the provider stops
accepting it — the password was changed, or access was revoked — the
connection says so and a notification asks you to sign in again.

## Know what is happening

- **An overview** of every connection — online, paused, unreachable or
  waiting for a sign-in — with the transfers under way and how much is kept
  on this Mac.
- **The menu bar** shows the same at a glance, with the transfers in progress
  and the conflicts that need a decision.
- **Notifications** when a server drops off, a sign-in expires, or the same
  file changed on both sides.
- **Remote changes** are looked for on a schedule set per connection — every
  30 seconds for file servers and a minute for cloud drives by default, or
  never — and the folders you have open in Finder update when they are found.

## Open a large file without downloading it

Opening a 4 GB archive fetches the bytes the system actually asks for, not the
whole file. Preview a video, read a header, seek through a log — the transfer
stops when it has what it came for.

## The right-click menu you would expect

Right-clicking anything under the Hamasen location offers:

| Action | What it does |
|---|---|
| **Copy remote path** | The address on the server |
| **Copy URL** | `sftp://`, `smb://`, the WebDAV or S3 address, or a cloud drive's web page — never a password |
| **Copy local path** | Where it sits under `~/Library/CloudStorage` |
| **Open in browser** | WebDAV, S3 objects (a presigned link valid for an hour) and cloud drives |
| **Open in Terminal** | SFTP servers: an `ssh://` session with your own keys and `~/.ssh/config` |
| **Show in Hamasen** | Brings the app forward on that connection |
| **Refresh** | Re-read the folder from the server |
| **Keep on this Mac** | Pin a file so nothing evicts it |
| **Stop keeping on this Mac** | Release the pin |
| **Free up local space** | Drop the downloaded copy, keep the file |
| **Unmount server** | Take that server out of Finder |

These come from the File Provider extension itself, so there is nothing to
enable and no permission to grant.

## Decide what stays on this Mac

Each server chooses how it uses local storage:

- **Automatic** — the system keeps what you have opened until it needs the room
- **Online only** — content is dropped as soon as it is no longer in use
- **A limit** — 1, 5, 20 or 100 GB per server, dropping the stalest content
  first and never touching anything you pinned

A gauge on each server shows what it is holding, split between what you pinned
and what can go. If pinned files alone exceed a limit, the app says so instead
of letting the limit quietly fail.

Across every connection, **auto-clean** drops local copies nobody has opened
for a while — 7 days, and above 10 GB in total, by default. Both are set in
Settings, and pinned files are never touched.

## Know the server is the server

The first time Hamasen connects over SSH it records the server's host key, and
every connection after that is checked against it. A key that does not match
stops the connection — a server may genuinely have been rebuilt, or something
may be answering in its place, and nothing on this side can tell those apart.

The recorded fingerprint is shown in the server's settings in the same form
`ssh-keygen -lf` prints, so it can be compared against the server itself, and
cleared there when a rebuild is the real explanation.

## Bring what you already have

- **Import from Cyberduck and Mountain Duck** — `.duck` bookmarks and
  `.cyberduckprofile` files, individually or a whole folder. Bookmarks on a
  protocol Hamasen does not speak are named back to you rather than dropped
  silently.
- **Back your configuration up** — the server list, the recorded host keys and
  the connection preferences, in a file you can read and diff. Passwords stay
  in the Keychain.
- **Or back everything up** — the same, plus every secret, sealed with a
  passphrase you choose. Restoring merges rather than replaces, so importing
  the wrong file costs a few servers to delete instead of everything.

## In your language

繁體中文, 简体中文, 日本語, 한국어 and English, following the system or set by
hand in Settings. Error messages are translated too, not just the buttons.

<p align="center">
  <img src="Docs/jp_finder.png" width="70%" alt="A mounted server open in Finder">
</p>

## Getting started

1. Build and run the app (see [Development](#development) — it is not on the
   App Store yet)
2. Follow **Getting Started** in the sidebar: add a connection, switch Hamasen
   on in **System Settings › General › Login Items & Extensions** (the ⓘ
   beside **File Providers**), allow notifications, find the connection in
   Finder, and choose whether Hamasen opens at login
3. To add a connection, press **+**, pick the kind of server, and enter the
   host and credentials — or sign in, for a cloud drive. The connection is
   tried before it is saved, and one that fails is not kept. For SFTP,
   **SSH Config › Import…** fills the host, port, user and key from a host in
   `~/.ssh/config`.
4. The first time a server on your local network is opened in Finder, macOS
   asks whether **HamasenFileProvider** may find devices on the local network.
   Allow it: the extension is its own identity, separate from the app, and
   without it LAN servers cannot be reached from Finder.

The mount survives quitting the app: the system keeps it up. The app needs to
be running for the space limits, auto-clean, change checks and notifications,
which it carries out as it runs.

## Compatibility

- macOS 15.6 or later, Apple silicon and Intel
- **SFTP** with a password or an SSH key (Ed25519 / RSA, OpenSSH format,
  encrypted keys included)
- **FTP** and **FTPS** (explicit `AUTH TLS`), passive mode
- **WebDAV** over HTTP or HTTPS, Basic authentication
- **SMB** 2.0 and 2.1, with a username and password
- **Google Drive**, **OneDrive** (personal and work or school) and
  **Dropbox**, signed in through the browser
- **S3-compatible object storage** — Cloudflare R2, Amazon S3, MinIO,
  Backblaze B2, Wasabi, and anything else speaking the same API. The region
  and the addressing style are read out of the hostname, and both can be set
  by hand for a provider that fits neither guess.

Plain FTP and plain WebDAV send credentials and contents in the clear. The
protocol picker says so where the choice is made; neither is a good idea over a
network you do not control. SMB is signed when the server requires it but
never encrypted, so the same goes for it. S3 is always HTTPS, except to a loopback address —
where there is no network for anything to travel over, and where a server
running on this Mac would otherwise be unreachable.

## Why "Hamasen" 哈瑪星?

**哈瑪星 (Hamasen)** is the historic harbor district of Kaohsiung, Taiwan. The
name is a Taiwanese rendering of the Japanese **浜線 (hamasen)** — the
shoreline railway that once carried cargo between the docks and the city.

This app plays the same role: a short line that brings remote servers ashore,
docking each one in Finder like a ship at the pier.

---

# Technical reference

## Architecture

```
Hamasen.xcodeproj
├── Hamasen                  Main app (SwiftUI)
│   └── Overview, connections, settings, onboarding, menu bar panel,
│       notifications, browser sign-in, change checks, auto-clean
├── HamasenFileProvider      File Provider extension
│   └── NSFileProviderReplicatedExtension: enumerate / fetch / create /
│       modify / delete, plus the Finder context-menu actions
└── HamasenCore              Local Swift package
    ├── RemoteFileService        The protocol every transport implements
    ├── SFTPFileService          Citadel (SwiftNIO SSH)
    ├── FTPFileService           Written here: control and data connections,
    │                            passive mode, MLSD/LIST, REST, AUTH TLS
    ├── WebDAVFileService        URLSession, no dependencies
    ├── S3FileService            URLSession over one REST API and one
    │                            signature, which is every S3-compatible
    │                            provider; AWSSignatureV4 written here
    ├── SMBFileService           SMBClient (SMB 2)
    ├── Cloud/                   Google Drive, OneDrive and Dropbox over
    │                            their REST APIs, on one HTTP client that
    │                            renews tokens and backs off when throttled
    ├── OAuth/                   Authorization code with PKCE, a loopback
    │                            redirect, and token renewal shared between
    │                            the app and the extension through the
    │                            Keychain
    ├── KnownHosts               Host keys, recorded on first use
    ├── ConfigurationArchive     Backup, plain and passphrase-sealed
    ├── CacheEvictionPlan        What to drop, given each server's allowance
    └── Storage/                 App Group JSON stores and the Keychain
```

**One File Provider domain.** The root enumerator lists each mounted server as
a top-level folder. Item identifiers encode the server and the path
(`srv:<uuid>:<path>`), so one extension serves any number of servers, each over
its own connection.

**Credentials live in the Data Protection Keychain**, in an access group the
app and the extension share. That entitlement comes from a provisioning
profile, which is why this build distributes through the App Store. Nothing
secret is written into the App Group container, which holds only the server
list, the mounted set, the pins and the host keys.

**Changes reach Finder through the working set**, the only container a
replicated extension is signalled for. The previous server list is encoded into
the sync anchor, so the change enumerator reports an exact diff without keeping
state between calls. A read that fails returns no anchor rather than an empty
one — an anchor claiming the mount was empty would make the next diff read as
every server having been deleted.

**Context menu entries are File Provider custom actions**, declared in the
extension's Info.plist with activation rules over `fileproviderItems`. This is
the mechanism Google Drive and Synology Drive use; Finder never asks a
FinderSync extension for menus on `~/Library/CloudStorage` paths.
Rules that depend on the protocol read it from each item's `userInfo`, so an
item listed before an update gains the new entries once its folder is
refreshed. `fileproviderctl evaluate <path>` shows the rules and their verdicts
without opening Finder, and a test pins the shipped plist against the Swift
side.

**A folder's custom picture** is the classic `Icon\r` file inside it, whose
resource fork holds the icon, and which the extension refuses to sync
(`excludedFromSync`), so it never reaches the server. The app writes it itself:
`NSWorkspace.setIcon` fails for a sandboxed app inside a File Provider domain.

**Backups with passwords** are PBKDF2-HMAC-SHA256 at 600,000 iterations into
AES-256-GCM. The whole file is encrypted, not only the secrets in it: which
servers someone has, and where, is worth as much to a reader as the passwords.
What may hold a secret is a different type from what a plain export writes, so
that export has nowhere to put one.

## Development

Requirements: Xcode 26+ (verified on the Xcode 27 beta) and an Apple
Development signing certificate.

```bash
./scripts/verify.sh          # package tests, then the app and extension build
./scripts/sync-strings.sh    # bring the String Catalogs in line with the source
```

Tests need no network and no external service. `HamasenCoreTests` stands up an
in-process SFTP server (Citadel's server API over a temp directory), an
in-process WebDAV server, an in-process FTP server and an in-process S3 server,
and runs the real clients against them. The S3 one verifies every signature it
is sent, so the hardest part of that protocol is exercised rather than assumed.
598 tests cover connecting with either credential type,
authentication failures, key parsing, listing, upload and download integrity,
ranged reads across chunk boundaries, create/delete/rename, the `remotePath`
base directory, item identifier encoding, misbehaving-server quirks
(redirects, 207, 416, ignored `Range` headers), FTP reply and listing parsing,
host key checking, the eviction plan, backup encryption, the diffing that
drives Finder updates, and Signature Version 4 pinned step by step against the
worked example Amazon publishes.

To see the app without pointing it at a real server:

```bash
cd HamasenCore && swift run DemoServers
```

It runs the same SFTP, FTP and S3 servers the tests use and prints what each
one needs. The two file servers hold a made-up home directory; the bucket holds
what a bucket holds — content hashes, date partitions and an empty folder that
exists only as the zero-byte object named after it.

### End-to-end tests

`E2E/` runs the real clients against real servers in Docker: OpenSSH, vsftpd
(FTP and FTPS), WebDAV over HTTP and HTTPS, Samba, SeaweedFS for S3, and a
mock of the Google Drive, OneDrive and Dropbox APIs that issues, renews and
revokes tokens the way they do. Toxiproxy sits in front of each, so latency,
dropped connections and stalls can be injected.

```bash
./scripts/e2e.sh up       # build and start the servers
./scripts/e2e.sh test     # conformance, faults and credential changes
./scripts/e2e.sh soak     # five simulated years of use
./scripts/e2e.sh down
```

The soak run compresses five years into a simulated calendar: daily edits,
renames and deletes on every service, server restarts and network faults each
month, passwords, host keys, certificates and sign-ins rotated each year, and
auto-clean run against the simulated dates. After each simulated month every
file is checked against a record of what it should contain. The report is
written to `E2E/.run/`. [E2E/CONTRACT.md](E2E/CONTRACT.md) lists the ports,
accounts and control commands.

To test across a real network, run the servers on another machine with Docker
and reach it over SSH: `HAMASEN_E2E_SSH=<host> ./scripts/e2e.sh up`, then
`test`, `soak` and `down` the same way. The services are copied to
`~/hamasen-e2e` there.

Keep Hamasen's own connections away from these servers while tests run. Every
run leaves folders behind on them, and a connection that mounts one indexes all
of it.

### Cloud drive sign-in

A source build carries no OAuth client IDs: a client ID ties every sign-in to
whoever registered it. Register an app with each provider you want to use and
enter its client ID in **Settings › Cloud Services**, which links to each
provider's console. The redirect address to register is
`http://127.0.0.1:53682/` (Google, Dropbox) or `http://localhost:53682/`
(Microsoft). A distributed build can carry its own in the app's Info.plist
under `HamasenGoogleClientID`, `HamasenMicrosoftClientID` and
`HamasenDropboxClientID`.

## Troubleshooting

### Finder stops responding at the Hamasen location

Finder asks fileproviderd about every item it draws, and waits for the answer.
When the location's database has grown huge, or the location has taken over a
folder left behind by an earlier one, fileproviderd stays busy with it and
Finder freezes — relaunching Finder does not help. How big the database is:

```bash
du -sh ~/Library/Application\ Support/FileProvider/*/database
```

**Settings › Local Copies › Reset Finder Location…** empties the location and
builds it again. Copies on this Mac go and are downloaded again when opened,
and so do edits that never reached a server; the servers are not touched.

### A server on the local network never loads in Finder

The extension needs its own **Local Network** permission, separate from the
app's. Without it the kernel drops its connections and Finder reports that the
server cannot be reached because Local Network access is off. Turn on
**HamasenFileProvider** in **System Settings › Privacy & Security › Local
Network**. To confirm that this is the cause:

```bash
/usr/bin/log show --last 5m --info --predicate 'process == "kernel" AND eventMessage CONTAINS "reason: NECP"'
```

Lines naming `HamasenFileProvi` mean the system is dropping its connections.

### The Finder context menu has lost its entries

If `fileproviderctl dump dev.hamasen.mac.FileProvider` shows the domain as
`unable to startup` with `database is locked`, Finder offers no provider
entries at all while browsing still works. Restart `fileproviderd`
(`killall fileproviderd`) and then Finder. If the check below reports the
location's database as damaged, use **Reset Finder Location…**.

The entries come from the extension's Info.plist, which the system reads
through whatever bundle PluginKit has on record. Archiving registers the
extension from the archive's intermediate build directory, and Xcode later
cleans that directory up — leaving a registration pointing at a bundle that
is no longer there. The mount keeps working, because the extension process
was already running; only the menu goes, because nothing can read the plist
that declares it.

Ask the system what it thinks the actions are:

```bash
fileproviderctl evaluate "$(ls -d ~/Library/CloudStorage/Hamasen-* | head -1)"
```

An empty `Actions:` list means none are registered, which is different from
a rule not matching — a rule that did not match would still be listed, with
`NO` after it. Then check where the registration points:

```bash
pluginkit -m -i dev.hamasen.mac.FileProvider -v
```

If that path does not exist, point the registration at a build that does and
restart the extension. Both paths are read rather than typed: the build
directory carries a hash particular to the checkout, and the stale one is
whatever PluginKit happens to hold.

```bash
stale="$(pluginkit -m -i dev.hamasen.mac.FileProvider -v | awk '{print $NF}' | head -1)"
built="$(xcodebuild -project Hamasen.xcodeproj -scheme Hamasen -configuration Debug \
    -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $2; exit}')"

[ -n "$stale" ] && pluginkit -r "$stale"
pluginkit -a "$built/Hamasen.app/Contents/PlugIns/HamasenFileProvider.appex"
pkill -f HamasenFileProvider
```

Removing and adding the same path is fine — that is what it looks like when
the registration is already correct and something else is wrong.

Running the app from Xcode after archiving does the same thing.

## Known limitations

- SSH keys must be in OpenSSH format (`-----BEGIN OPENSSH PRIVATE KEY-----`);
  ECDSA and older PKCS#1 PEM keys are not supported. Convert with
  `ssh-keygen -p -f <key>`.
- Uploads are read into memory before being sent; downloads stream.
- Remote changes are found by checking on a schedule, not pushed as they
  happen, and only in folders the system holds — ones somebody has opened.
- Space limits, auto-clean and change checks run while the app is running.
- Google Docs, Sheets and Slides appear as read-only exports, since they have
  no file to download.
- FTPS reuses no TLS session between the control and data connections, so a
  server configured to require that will refuse the transfers.
- An FTP server without `MLSD` (vsftpd, for one) lists modification times to
  the minute, so an edit made on the server that keeps the file's size and
  lands in the same minute is not noticed until the file changes again.
- The Finder context menu follows the system language, not the app's: Finder
  draws that menu and reads the names in its own language.

Object storage is not a file system, and three of the differences are visible:

- **Nothing is renamed.** Moving a file copies it on the server and deletes the
  original; moving a folder does that once per object inside it. Everything is
  copied before anything is deleted, so an interrupted move leaves the source
  intact and some duplicates behind rather than losing what had not been copied.
- **An empty folder is one zero-byte object** named after it. That is the only
  form it can take, so a folder made by another tool may not be there, and one
  made here may not show up in a tool that hides such objects.
- **A key can name both an object and a folder**, since `a` says nothing about
  `a/b`. Finder cannot show one name twice: the object is shown, and what lies
  under the prefix is not reachable.

Listing a bucket costs requests, which some providers bill for. Browsing in
Finder issues them as you go.

Planned: streaming uploads.

<p>
  <img alt="SwiftUI" src="https://img.shields.io/badge/SWIFTUI-0071E3?style=for-the-badge&logo=swift&logoColor=white">
  <a href="https://github.com/apple/swift-nio"><img alt="SwiftNIO" src="https://img.shields.io/badge/SWIFTNIO-F05138?style=for-the-badge&logo=swift&logoColor=white"></a>
  <a href="https://github.com/orlandos-nl/Citadel"><img alt="Citadel" src="https://img.shields.io/badge/CITADEL-SSH-7F52FF?style=for-the-badge"></a>
  <img alt="598 tests" src="https://img.shields.io/badge/TESTS-598-4CAF50?style=for-the-badge&logo=swift&logoColor=white">
  <a href="LICENSE"><img alt="License: Apache 2.0" src="https://img.shields.io/badge/LICENSE-APACHE_2.0-2196F3?style=for-the-badge&logo=github"></a>
</p>


## Support

If Hamasen is useful to you, you can support development:

<a href="https://buymeacoffee.com/doershing"><img alt="Buy Me a Coffee" src="https://img.shields.io/badge/Buy%20Me%20a%20Coffee-doershing-FFDD00?style=for-the-badge&logo=buymeacoffee&logoColor=black"></a>

## License

[Apache 2.0](LICENSE) © KoukeNeko

Third-party components keep their own terms: [Citadel](https://github.com/orlandos-nl/Citadel)
and [SMBClient](https://github.com/kishikawakatsumi/SMBClient) are MIT, and
Apple's [SwiftNIO](https://github.com/apple/swift-nio) packages are Apache 2.0.
The service logos come from [theSVG](https://thesvg.org)
([glincker/thesvg](https://github.com/glincker/thesvg), MIT).

### Trademarks

Google Drive is a trademark of Google LLC. OneDrive is a trademark of the
Microsoft group of companies. Dropbox is a trademark of Dropbox, Inc. Other
names and logos are trademarks of their respective owners, used only to
identify the services Hamasen connects to. Hamasen is not affiliated with or
endorsed by any of these companies.
