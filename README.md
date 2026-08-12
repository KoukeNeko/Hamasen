# Hamasen 哈瑪星

A macOS app that mounts remote SFTP servers into the Finder sidebar, the same
way iCloud Drive and OneDrive appear — browse, open, edit, and drag files
without a separate client window.

Built on Apple's official **File Provider** framework
(`NSFileProviderReplicatedExtension`) — no macFUSE, no kernel extensions,
App Store compatible.

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
│   └── KeychainCredentialStore  Passwords live in the Keychain only
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
- Mount, unmount, and rename changes reach Finder immediately: the root
  sync anchor is a hash of the mounted-server list, and the app signals the
  enumerator whenever the list changes.
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
in-process SFTP server (Citadel's server API over a local temp directory).
17 tests cover connection, authentication failure, directory listing,
upload/download content integrity, create/delete/rename, and the
`remotePath` base directory.

## Manual end-to-end check

1. Open the project in Xcode and run the **Hamasen** scheme (⌘R).
2. Add an SFTP server (host, username, password) and press **掛載** (Mount).
3. The **Hamasen** location appears in the Finder sidebar; the server shows
   up inside as a folder.
4. On-disk storage lives under `~/Library/CloudStorage/`.

## Status

- [x] SFTP with password authentication
- [x] Finder integration: browse, download on open, upload, new folders,
      rename, move, delete
- [x] Per-server folders under a single Finder location
- [ ] Planned: FTP/FTPS, SSH key authentication, host key verification
      (TOFU), streaming transfers for large files, remote change tracking

Known limitations:

- Transfers are whole-file in memory; multi-GB files will be hungry until
  streaming lands.
- Host keys are currently accepted blindly (`acceptAnything`); TOFU pinning
  is planned.
- Remote changes are picked up on re-enumeration (Finder refresh), not
  pushed live.
