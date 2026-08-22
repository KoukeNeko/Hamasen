<div align="center">

<img src="Docs/hamasen-iOS-Default-1024@1x.png" width="160" alt="Hamasen app icon">

# Hamasen 哈瑪星

---

**Your servers, docked in Finder.**\
Mount remote SFTP servers as native Finder locations — browse, edit, and drag files like local folders.

[![Platform](https://img.shields.io/badge/platform-macOS%2015.6%2B-blue?style=for-the-badge&logo=apple)](https://github.com/KoukeNeko/Hamasen)
[![Swift](https://img.shields.io/badge/Swift-5-orange?style=for-the-badge&logo=swift)](https://github.com/KoukeNeko/Hamasen)
[![File Provider](https://img.shields.io/badge/File%20Provider-no%20kexts%2C%20no%20macFUSE-green?style=for-the-badge)](https://developer.apple.com/documentation/fileprovider)
[![Stars](https://img.shields.io/github/stars/KoukeNeko/Hamasen?style=for-the-badge&logo=github)](https://github.com/KoukeNeko/Hamasen/stargazers)

[Why "Hamasen"?](#why-hamasen-哈瑪星) · [Architecture](#architecture) · [Development](#development)

</div>

Hamasen mounts remote SFTP servers into the Finder sidebar, the same way
iCloud Drive and OneDrive appear — browse, open, edit, and drag files
without a separate client window.

It is built on Apple's official **File Provider** framework
(`NSFileProviderReplicatedExtension`): no macFUSE, no kernel extensions,
App Store compatible.

## Why "Hamasen" 哈瑪星?

**哈瑪星 (Hamasen)** is the historic harbor district of Kaohsiung, Taiwan.
The name is a Taiwanese rendering of the Japanese **浜線 (hamasen)** — the
shoreline railway that once carried cargo between the docks and the city.

This app plays the same role: a short line that brings remote servers
ashore, docking each one in Finder like a ship at the pier.

## How it looks

Finder shows a single **Hamasen** location. Every mounted server appears
inside it as a folder named after the server:

```
Finder sidebar
└── Hamasen
    ├── Production NAS/     ← one folder per mounted server
    │   └── upload/ …          (live SFTP content)
    └── Staging VPS/
```

## Architecture

```
Hamasen.xcodeproj
├── Hamasen                  Main app (SwiftUI)
│   └── Server list, add/edit connections, mount/unmount
├── HamasenFileProvider      File Provider extension
│   └── NSFileProviderReplicatedExtension: enumerate / fetch / create / modify / delete,
│       plus the Finder context-menu actions (NSFileProviderCustomAction)
├── HamasenCore              Local Swift package
│   ├── RemoteFileService        Protocol abstraction (FTP can plug in later)
│   ├── SFTPFileService          Citadel (SwiftNIO SSH) implementation
│   ├── WebDAVFileService        URLSession implementation, no dependencies
│   ├── ServerConfigStore        JSON config in the App Group container
│   ├── MountedServersStore      Which servers are currently mounted
│   └── KeychainCredentialStore  Passwords and keys live in the Keychain only
└── Config/                  Entitlements and extension Info.plist
```

Key design points:

- **Single File Provider domain** (`dev.hamasen.main`): the root enumerator
  lists each mounted server as a top-level folder. Item identifiers encode
  the server and path (`srv:<uuid>:<path>`), so one extension serves any
  number of servers, each over its own SSH connection.
- The app and the extension share configuration through an **App Group**
  (`33832Z66QU.group.dev.hamasen.shared`). Credentials stay in the macOS
  file-based Keychain, with an item ACL that trusts the signed app and File
  Provider extension; no secret is written into the App Group container.
- Mount, unmount, and rename changes reach Finder through the **working
  set**, the only container a replicated extension receives change signals
  for. The previous server list is encoded into the sync anchor, so the
  change enumerator can report an exact diff without keeping state between
  calls.
- Server folders cannot be renamed, moved, or deleted from Finder — they are
  managed in the app. Cross-server moves fall back to copy + delete.
- Context menu entries are **File Provider custom actions**: the extension
  declares them in its Info.plist (`NSExtensionFileProviderActions`, with
  activation rules over `fileproviderItems`) and runs them through
  `NSFileProviderCustomAction`. This is how Google Drive and Synology Drive
  add their entries; Finder never asks a FinderSync extension for menus on
  `~/Library/CloudStorage` paths. `fileproviderctl evaluate <path>` shows the
  rules and their verdicts without opening Finder, and
  `FinderActivationRuleTests` pins the shipped plist.

## Development

Requirements: Xcode 26+ (verified with the Xcode 27 beta) and an Apple
Development signing certificate. Shipping the app outside the Mac App Store
also needs a Developer ID Application certificate and notarization credentials.

```bash
# Source verification: package tests + app/extension build
./scripts/verify.sh
```

Tests need no external infrastructure: `HamasenCoreTests` spins up an
in-process SFTP server (Citadel's server API over a local temp directory)
that accepts both password and public key authentication, plus an
in-process WebDAV server. 99 tests cover
connecting with either credential type, authentication failures, key
parsing, directory listing, upload/download content integrity, range
requests across chunk boundaries, create/delete/rename, the `remotePath`
base directory, item identifier encoding, misbehaving-server quirks
(redirects, 207, 416, ignored `Range` headers), and the mounted-server
diffing that drives Finder updates.

### Developer ID installation and notarization

For distribution outside the Mac App Store, the app and its File Provider
extension are Developer ID-signed and notarized before being installed in
`/Applications`. The installer also retracts the PluginKit and Launch Services
records of the FinderSync extension and helper app that releases up to 1.0
shipped, since those registrations outlive the bundles they name.

Distribution goes through the App Store. Credentials live in the Data
Protection Keychain, in an access group the app and the File Provider
extension share, and that entitlement is granted by a provisioning profile —
which is why a Developer ID build signed without one can no longer read them.

Archive from Xcode (Product → Archive), notarize and export through the
Organizer, then package what comes out:

```bash
./scripts/release.sh /path/to/exported/Hamasen.app v1.0.0-beta.1
```

The script refuses to package a build a downloader could not use: unsigned or
signed by another team, no stapled notarization ticket, rejected by
Gatekeeper, an extension missing its document group, or an app and an
extension that disagree about the macOS they need.

## Showing the app without a real server

Two servers run on this Mac, serving invented files, so the app can be
demonstrated or photographed without a real hostname and account in the
picture. They are the ones the test suite already runs the client against.

```bash
cd HamasenCore && swift run DemoServers
```

It prints the ports, the account, and a one-line `/etc/hosts` entry that
gives them names — `files.hamasen.test` and `ftp.hamasen.test`, under the TLD
RFC 2606 reserves so they can never resolve to anybody else's machine. Names
have to come from `/etc/hosts` rather than DNS: a public record pointing at
127.0.0.1 is exactly what DNS rebinding protection discards, and home routers
and VPN resolvers do discard it.

Ctrl-C stops them; nothing survives.

## Manual end-to-end check

1. Open the project in Xcode and run the **Hamasen** scheme (⌘R).
2. Add an SFTP server (host, username, and either a password or an SSH key)
   and press **掛載** (Mount).
3. The **Hamasen** location appears in the Finder sidebar; the server shows
   up inside as a folder.
4. On-disk storage lives under `~/Library/CloudStorage/`.

## Status

- [x] SFTP with password or SSH key authentication (Ed25519 / RSA, OpenSSH
      format, encrypted keys supported)
- [x] WebDAV and WebDAV over HTTPS, with Basic authentication
- [x] FTP and FTPS (explicit `AUTH TLS`), with passive-mode transfers,
      MLSD listings where the server offers them and `ls -l` parsing where
      it does not, and ranged reads through `REST`
- [x] Finder integration: browse, download on open, upload, new folders,
      rename, move, delete
- [x] Per-server folders under a single Finder location
- [x] Range requests: opening a large file fetches only the bytes the system
      asks for, rather than downloading the whole thing
- [x] Finder context menu: copy an item's remote address, refresh, free up
      local space (evict downloaded copies), unmount a server — provided by
      the File Provider extension itself, so nothing needs enabling in System
      Settings
- [x] Import from Cyberduck and Mountain Duck: `.duck` bookmarks and
      `.cyberduckprofile` files, keeping the ones on a protocol this app
      speaks and naming the ones it does not. Passwords stay behind, in
      Cyberduck's own Keychain items
- [x] SSH host keys recorded on first use and checked on every connection
      after, with the recorded key shown and clearable per server
- [ ] Planned: streaming uploads, remote change tracking

Known limitations:

- SSH keys must be in OpenSSH format (`-----BEGIN OPENSSH PRIVATE KEY-----`);
  ECDSA keys and older PKCS#1 PEM keys are not supported. Convert with
  `ssh-keygen -p -f <key>`.
- Uploads are read into memory before being sent; downloads stream.
- FTPS reuses no TLS session between the control and data connections, so a
  server configured to require that will refuse the transfers.
- Plain FTP and plain WebDAV send credentials and contents in the clear. The
  protocol picker says so; neither is a good choice over a network you do not
  control.
- Remote changes are picked up on re-enumeration (Finder refresh), not
  pushed live.
