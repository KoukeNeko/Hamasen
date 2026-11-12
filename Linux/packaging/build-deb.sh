#!/bin/sh
# Builds hamasen_<version>_all.deb next to this script. Usage: build-deb.sh [version]
set -e
here=$(cd "$(dirname "$0")" && pwd)
src=$(dirname "$here")
version=${1:-0.1.0}
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

install -d "$root/usr/lib/hamasen" "$root/usr/bin" "$root/usr/share/applications" \
    "$root/usr/share/icons/hicolor/512x512/apps" "$root/DEBIAN"
install -m 644 "$src/hamasen.py" "$src/core.py" "$src/i18n.py" "$src/tray.py" "$root/usr/lib/hamasen/"
chmod 755 "$root/usr/lib/hamasen/hamasen.py"
printf '#!/bin/sh\nexec /usr/bin/python3 /usr/lib/hamasen/hamasen.py "$@"\n' > "$root/usr/bin/hamasen"
chmod 755 "$root/usr/bin/hamasen"
sed -e "s|@EXEC@|hamasen|" -e "s|@ICON@|app.hamasen.Hamasen|" "$src/app.hamasen.Hamasen.desktop" \
    > "$root/usr/share/applications/app.hamasen.Hamasen.desktop"
# The app icon is 1024px; the hicolor theme tops out at 512.
/usr/bin/python3 - "$src/../Docs/app-icon.png" "$root/usr/share/icons/hicolor/512x512/apps/app.hamasen.Hamasen.png" <<'PY'
import sys
import gi
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import GdkPixbuf
GdkPixbuf.Pixbuf.new_from_file_at_size(sys.argv[1], 512, 512).savev(sys.argv[2], "png", [], [])
PY

cat > "$root/DEBIAN/control" <<CONTROL
Package: hamasen
Version: $version
Architecture: all
Section: net
Priority: optional
Maintainer: KoukeNeko <111033412+KoukeNeko@users.noreply.github.com>
Depends: python3, python3-gi, gir1.2-gtk-4.0, gir1.2-adw-1, gir1.2-secret-1, gvfs-backends, gvfs-fuse
Recommends: rclone, fuse3
Homepage: https://github.com/KoukeNeko/Hamasen
Description: Mount remote servers and cloud drives in the file manager
 Hamasen keeps a list of SFTP, FTP, SMB, WebDAV and NFS servers and mounts
 them through GVfs, so they appear in the file manager sidebar. Google
 Drive, OneDrive, Dropbox and S3-compatible storage are mounted through
 rclone. Passwords are kept in the desktop keyring.
CONTROL
find "$root" -type d -exec chmod 755 {} +
find "$root/usr/share" -type f -exec chmod 644 {} +
dpkg-deb --root-owner-group --build "$root" "$here/hamasen_${version}_all.deb"
