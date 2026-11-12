#!/bin/sh
# Builds hamasen_<version>_all.deb next to this script. Usage: build-deb.sh [version]
set -e
here=$(cd "$(dirname "$0")" && pwd)
src=$(dirname "$here")
# core.py needs GTK to import, which a CI runner may lack, so read the line instead.
version=${1:-$(sed -n 's/^VERSION = "\(.*\)"/\1/p' "$src/core.py")}
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

install -d "$root/usr/lib/hamasen" "$root/usr/bin" "$root/usr/share/applications" \
    "$root/usr/share/icons/hicolor/512x512/apps" "$root/DEBIAN"
install -m 644 "$src/hamasen.py" "$src/core.py" "$src/contributors.py" "$src/i18n.py" "$src/tray.py" "$root/usr/lib/hamasen/"
# A package lists its contributors as of the build instead of asking GitHub on every launch.
/usr/bin/python3 "$src/contributors.py" "$root/usr/lib/hamasen/contributors.json"
chmod 755 "$root/usr/lib/hamasen/hamasen.py"
printf '#!/bin/sh\nexec /usr/bin/python3 /usr/lib/hamasen/hamasen.py "$@"\n' > "$root/usr/bin/hamasen"
chmod 755 "$root/usr/bin/hamasen"
sed -e "s|@EXEC@|hamasen|" -e "s|@ICON@|app.hamasen.Hamasen|" "$src/app.hamasen.Hamasen.desktop" \
    > "$root/usr/share/applications/app.hamasen.Hamasen.desktop"
install -m 644 "$src/data/icons/hicolor/512x512/apps/app.hamasen.Hamasen.png" "$root/usr/share/icons/hicolor/512x512/apps/"

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
