<div align="center">

<img src="Docs/hamasen-iOS-Default-1024@1x.png" width="160" alt="Hamasen app icon">

# Hamasen 哈瑪星

---

**Your servers, docked in Finder.**\
Mount remote SFTP servers as native Finder locations — browse, edit, and drag files like local folders.

[![Platform](https://img.shields.io/badge/platform-macOS%2026%2B-blue?style=for-the-badge&logo=apple)](https://github.com/KoukeNeko/Hamasen)
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
│   └── NSFileProviderReplicatedExtension: enumerate / fetch / create / modify / delete
├── HamasenCore              Local Swift package
│   ├── RemoteFileService        Protocol abstraction (FTP can plug in later)
│   ├── SFTPFileService          Citadel (SwiftNIO SSH) implementation
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
  (`group.dev.hamasen.shared`); credentials are shared via the Data
  Protection Keychain using the same group.
- Mount, unmount, and rename changes reach Finder through the **working
  set**, the only container a replicated extension receives change signals
  for. The previous server list is encoded into the sync anchor, so the
  change enumerator can report an exact diff without keeping state between
  calls.
- Server folders cannot be renamed, moved, or deleted from Finder — they are
  managed in the app. Cross-server moves fall back to copy + delete.

## Development

Requirements: Xcode 26+ (verified with the Xcode 27 beta) and an Apple
Development signing certificate.

```bash
# Full verification: package tests + app/extension build
./scripts/verify.sh
```

Tests need no external infrastructure: `HamasenCoreTests` spins up an
in-process SFTP server (Citadel's server API over a local temp directory)
that accepts both password and public key authentication. 50 tests cover
connecting with either credential type, authentication failures, key
parsing, directory listing, upload/download content integrity, range
requests across chunk boundaries, create/delete/rename, the `remotePath`
base directory, and the mounted-server diffing that drives Finder updates.

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
- [x] Finder integration: browse, download on open, upload, new folders,
      rename, move, delete
- [x] Per-server folders under a single Finder location
- [x] Range requests: opening a large file fetches only the bytes the system
      asks for, rather than downloading the whole thing
- [ ] Planned: FTP/FTPS, WebDAV, host key verification (TOFU), streaming
      uploads, remote change tracking

Known limitations:

- SSH keys must be in OpenSSH format (`-----BEGIN OPENSSH PRIVATE KEY-----`);
  ECDSA keys and older PKCS#1 PEM keys are not supported. Convert with
  `ssh-keygen -p -f <key>`.
- Uploads are read into memory before being sent; downloads stream.
- Host keys are currently accepted blindly (`acceptAnything`); TOFU pinning
  is planned.
- Remote changes are picked up on re-enumeration (Finder refresh), not
  pushed live.
