The first beta of Hamasen 哈瑪星: your servers and cloud drives as native
Finder locations, through macOS's own File Provider — no macFUSE, no kernel
extension.

This is a pre-release. It has been used daily against real servers, but not
widely tested yet.

## Requirements

macOS 15.6 or later. Development and daily use have been on macOS 27.

## What's in it

- **SFTP** (password or SSH key, with import from `~/.ssh/config`), **FTP /
  FTPS**, **WebDAV**, **SMB**, **S3-compatible storage** (R2, S3, MinIO, B2,
  Wasabi), and **Google Drive, OneDrive and Dropbox** signed in through the
  browser
- Every connection is a folder in one **Hamasen** Finder location, with its
  own color, symbol, emoji or picture, and can be paused
- Large files open without downloading the whole file
- **Right-click menu**: copy remote path, URL or local path, open in browser
  or Terminal, show in Hamasen, refresh, keep on this Mac, free up space,
  unmount
- What stays on this Mac per connection — automatic, online only, or a size
  limit — plus auto-clean of copies nobody opened for a while
- SSH host keys recorded on first connection and checked every time after
- An overview of every connection and transfer, a menu bar status, and
  notifications for unreachable servers, expired sign-ins and conflicts
- Import from Cyberduck and Mountain Duck; back the configuration up, with or
  without passwords
- 繁體中文, 简体中文, 日本語, 한국어 and English

## Installing

Open `Hamasen-1.0-beta.1.dmg` and drag Hamasen to Applications. On first
launch, follow **Getting Started**: switch Hamasen on under **System Settings
› General › Login Items & Extensions › File Providers**. The first time a
server on your local network is opened in Finder, allow
**HamasenFileProvider** to find devices on the local network.

## Known limitations

- SSH keys must be in OpenSSH format; ECDSA and PKCS#1 PEM keys are not
  supported (`ssh-keygen -p -f <key>` converts them)
- Uploads are read into memory before being sent; downloads stream
- Remote changes are found by checking on a schedule, only in folders that
  have been opened
- Space limits, auto-clean and change checks run while the app is running
- Google Docs, Sheets and Slides appear as read-only Office exports
