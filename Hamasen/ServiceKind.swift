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

/// The kinds of storage a person chooses between when adding a connection.
///
/// Coarser than `TransferProtocol`: WebDAV over HTTP or HTTPS is one choice
/// made by the address typed, and FTP or FTPS one choice with an encryption
/// switch, because that is how people think of them.
enum ServiceKind: String, CaseIterable, Identifiable {
    case webdav
    case smb
    case sftp
    case ftp
    case googleDrive
    case oneDrive
    case dropbox
    case s3

    enum Category: CaseIterable, Identifiable {
        case servers
        case cloudDrives
        case objectStorage

        var id: Self { self }

        var title: LocalizedStringKey {
            switch self {
            case .servers: return "NAS 與伺服器"
            case .cloudDrives: return "雲端硬碟"
            case .objectStorage: return "物件儲存"
            }
        }

        var kinds: [ServiceKind] { ServiceKind.allCases.filter { $0.category == self } }
    }

    var id: Self { self }

    init(_ transferProtocol: ServerConfig.TransferProtocol) {
        switch transferProtocol {
        case .webdav, .webdavs: self = .webdav
        case .smb: self = .smb
        case .sftp: self = .sftp
        case .ftp, .ftps: self = .ftp
        case .googleDrive: self = .googleDrive
        case .oneDrive: self = .oneDrive
        case .dropbox: self = .dropbox
        case .s3: self = .s3
        }
    }

    var category: Category {
        switch self {
        case .webdav, .smb, .sftp, .ftp: return .servers
        case .googleDrive, .oneDrive, .dropbox: return .cloudDrives
        case .s3: return .objectStorage
        }
    }

    /// The protocol a new connection of this kind starts with.
    var defaultProtocol: ServerConfig.TransferProtocol {
        switch self {
        case .webdav: return .webdavs
        case .smb: return .smb
        case .sftp: return .sftp
        case .ftp: return .ftps
        case .googleDrive: return .googleDrive
        case .oneDrive: return .oneDrive
        case .dropbox: return .dropbox
        case .s3: return .s3
        }
    }

    var title: String {
        switch self {
        case .webdav: return "WebDAV"
        case .smb: return "SMB"
        case .sftp: return "SFTP"
        case .ftp: return "FTP / FTPS"
        case .googleDrive: return ServerConfig.TransferProtocol.googleDrive.displayName
        case .oneDrive: return "OneDrive"
        case .dropbox: return "Dropbox"
        case .s3: return String(localized: "S3 相容儲存")
        }
    }

    /// What it is for, shown where the kind is chosen.
    var summary: LocalizedStringKey {
        switch self {
        case .webdav: return "Synology、QNAP、Nextcloud 等 NAS"
        case .smb: return "區域網路內的 Windows 或 NAS 共用資料夾"
        case .sftp: return "透過 SSH 連到 Linux 或 macOS 伺服器"
        case .ftp: return "網站主機與較舊的裝置"
        case .googleDrive: return "用 Google 帳號在瀏覽器登入"
        case .oneDrive: return "用 Microsoft 帳號在瀏覽器登入"
        case .dropbox: return "用 Dropbox 帳號在瀏覽器登入"
        case .s3: return "AWS S3、Cloudflare R2、Wasabi、MinIO"
        }
    }

    var symbol: String {
        switch self {
        case .webdav: return "server.rack"
        case .smb: return "network"
        case .sftp: return "apple.terminal.fill"
        case .ftp: return "arrow.up.arrow.down"
        case .googleDrive: return "triangle.fill"
        case .oneDrive: return "cloud.fill"
        case .dropbox: return "shippingbox.fill"
        case .s3: return "cylinder.split.1x2.fill"
        }
    }

    var tint: Color {
        switch self {
        case .webdav: return .blue
        case .smb: return .teal
        case .sftp: return .indigo
        case .ftp: return .pink
        case .googleDrive: return .green
        case .oneDrive: return .cyan
        case .dropbox: return .blue
        case .s3: return .orange
        }
    }
}

/// A symbol on a tinted rounded square, the way System Settings draws the
/// icons in its sidebar and pane headers.
struct SymbolTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// A service's icon, so a connection is recognisable at a glance in the
/// sidebar, the overview and the menu bar: the provider's own logo for a
/// cloud drive, a symbol tile for every protocol.
struct ServiceIcon: View {
    let kind: ServiceKind
    var size: CGFloat = 20

    var body: some View {
        if let logo = kind.brandLogo {
            let shape = RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            Image(logo.asset)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(logo.isTile ? 0 : size * 0.14)
                .frame(width: size, height: size)
                .background(logo.isTile ? Color.clear : Color.white, in: shape)
                .clipShape(shape)
                .overlay(shape.strokeBorder(.black.opacity(logo.isTile ? 0 : 0.08), lineWidth: 0.5))
                .accessibilityHidden(true)
        } else {
            SymbolTile(symbol: kind.symbol, tint: kind.tint, size: size)
        }
    }
}

extension ServiceKind {
    /// The provider's logo, from thesvg.org. The marks belong to their
    /// owners; About lists them.
    struct BrandLogo {
        let asset: String
        /// Whether the artwork is already a filled square, as Dropbox's is.
        let isTile: Bool
    }

    var brandLogo: BrandLogo? {
        switch self {
        case .googleDrive: return BrandLogo(asset: "BrandGoogleDrive", isTile: false)
        case .oneDrive: return BrandLogo(asset: "BrandOneDrive", isTile: false)
        case .dropbox: return BrandLogo(asset: "BrandDropbox", isTile: true)
        case .webdav, .smb, .sftp, .ftp, .s3: return nil
        }
    }
}

extension ServerConfig {
    var serviceKind: ServiceKind { ServiceKind(transferProtocol) }

    /// What the connection points at, beneath its name: the account for a
    /// cloud drive, the host for everything else.
    var addressSummary: String {
        if transferProtocol.oauthProvider != nil {
            return username.isEmpty ? transferProtocol.displayName : username
        }
        return host
    }
}
