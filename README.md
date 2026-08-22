<p align="center">
  <img src="Docs/hamasen-iOS-Default-1024@1x.png" alt="Hamasen" width="160">
</p>

<h1 align="center">Hamasen 哈瑪星</h1>

<p align="center">
  <strong>Your servers, docked in Finder.</strong><br>
  Mount SFTP, FTP and WebDAV servers as native Finder locations — browse, open,
  edit and drag files without a separate client window.
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

## Open a large file without downloading it

Opening a 4 GB archive fetches the bytes the system actually asks for, not the
whole file. Preview a video, read a header, seek through a log — the transfer
stops when it has what it came for.

## The right-click menu you would expect

Right-clicking anything under the Hamasen location offers:

| Action | What it does |
|---|---|
| **Copy remote path** | The address on the server |
| **Copy local path** | Where it sits under `~/Library/CloudStorage` |
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

繁體中文, 日本語 and English, following the system or set by hand in Settings.
Error messages are translated too, not just the buttons.

<p align="center">
  <img src="Docs/jp_finder.png" width="70%" alt="A mounted server open in Finder">
</p>

## Getting started

1. Build and run the app (see [Development](#development) — it is not on the
   App Store yet)
2. Press **+** and enter the host, the username, and a password or SSH key
3. Press **Test connection** to check it before committing to it
4. Press **Mount**
5. Open Finder — **Hamasen** is in the sidebar, with your server inside it

The mount survives quitting the app: the system keeps it up. The app needs to
be running only for the per-server space limits, which it enforces as it runs.

## Compatibility

- macOS 15.6 or later, Apple silicon
- **SFTP** with a password or an SSH key (Ed25519 / RSA, OpenSSH format,
  encrypted keys included)
- **FTP** and **FTPS** (explicit `AUTH TLS`), passive mode
- **WebDAV** over HTTP or HTTPS, Basic authentication

Plain FTP and plain WebDAV send credentials and contents in the clear. The
protocol picker says so where the choice is made; neither is a good idea over a
network you do not control.

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
│   └── Server list, connection editing, mounting, settings, backup
├── HamasenFileProvider      File Provider extension
│   └── NSFileProviderReplicatedExtension: enumerate / fetch / create /
│       modify / delete, plus the Finder context-menu actions
└── HamasenCore              Local Swift package
    ├── RemoteFileService        The protocol every transport implements
    ├── SFTPFileService          Citadel (SwiftNIO SSH)
    ├── FTPFileService           Written here: control and data connections,
    │                            passive mode, MLSD/LIST, REST, AUTH TLS
    ├── WebDAVFileService        URLSession, no dependencies
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
`fileproviderctl evaluate <path>` shows the rules and their verdicts without
opening Finder, and a test pins the shipped plist against the Swift side.

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
in-process WebDAV server, and an in-process FTP server, and runs the real
clients against them. 209 tests cover connecting with either credential type,
authentication failures, key parsing, listing, upload and download integrity,
ranged reads across chunk boundaries, create/delete/rename, the `remotePath`
base directory, item identifier encoding, misbehaving-server quirks
(redirects, 207, 416, ignored `Range` headers), FTP reply and listing parsing,
host key checking, the eviction plan, backup encryption, and the diffing that
drives Finder updates.

To see the app without pointing it at a real server:

```bash
cd HamasenCore && swift run DemoServers
```

It runs the same SFTP and FTP servers the tests use, over invented files, and
prints the ports, the account and an `/etc/hosts` line that gives them names.

## Troubleshooting

### The Finder context menu has lost its entries

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

## Releasing

Archive from Xcode (Product → Archive), notarize and export through the
Organizer, then package what comes out:

```bash
./scripts/release.sh <the exported Hamasen.app> <tag>   # e.g. v1.0.0-beta.1
```

Both are arguments that differ every time — where the Organizer put the export
is a choice made in the panel, and the tag is whatever is being released.

The script refuses to package a build a downloader could not use: unsigned or
signed by another team, no stapled notarization ticket, rejected by Gatekeeper,
an extension missing its document group, or an app and an extension that
disagree about the macOS they need.

## Known limitations

- SSH keys must be in OpenSSH format (`-----BEGIN OPENSSH PRIVATE KEY-----`);
  ECDSA and older PKCS#1 PEM keys are not supported. Convert with
  `ssh-keygen -p -f <key>`.
- Uploads are read into memory before being sent; downloads stream.
- Remote changes are picked up on re-enumeration (a Finder refresh), not
  pushed as they happen.
- A per-server space limit is enforced while the app is running.
- FTPS reuses no TLS session between the control and data connections, so a
  server configured to require that will refuse the transfers.
- The Finder context menu follows the system language, not the app's: Finder
  draws that menu and reads the names in its own language.

Planned: streaming uploads, remote change tracking.

<p>
  <img alt="SwiftUI" src="https://img.shields.io/badge/SWIFTUI-0071E3?style=for-the-badge&logo=swift&logoColor=white">
  <a href="https://github.com/apple/swift-nio"><img alt="SwiftNIO" src="https://img.shields.io/badge/SWIFTNIO-F05138?style=for-the-badge&logo=swift&logoColor=white"></a>
  <a href="https://github.com/orlandos-nl/Citadel"><img alt="Citadel" src="https://img.shields.io/badge/CITADEL-SSH-7F52FF?style=for-the-badge"></a>
  <img alt="209 tests" src="https://img.shields.io/badge/TESTS-209-4CAF50?style=for-the-badge&logo=swift&logoColor=white">
  <a href="LICENSE"><img alt="License: Apache 2.0" src="https://img.shields.io/badge/LICENSE-APACHE_2.0-2196F3?style=for-the-badge&logo=github"></a>
</p>

## License

[Apache 2.0](LICENSE) © KoukeNeko

Third-party components keep their own terms: [Citadel](https://github.com/orlandos-nl/Citadel)
is MIT, and Apple's [SwiftNIO](https://github.com/apple/swift-nio) packages are
Apache 2.0.
