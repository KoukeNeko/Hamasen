#!/bin/sh
# Installs a launcher for the current user that points at this checkout.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
chmod +x "$dir/hamasen.py"
mkdir -p "$HOME/.local/share/applications"
sed -e "s|@EXEC@|/usr/bin/python3 $dir/hamasen.py|" -e "s|@ICON@|app.hamasen.Hamasen|" \
    "$dir/app.hamasen.Hamasen.desktop" > "$HOME/.local/share/applications/app.hamasen.Hamasen.desktop"
mkdir -p "$HOME/.local/share/icons/hicolor/512x512/apps"
cp "$dir/data/icons/hicolor/512x512/apps/app.hamasen.Hamasen.png" "$HOME/.local/share/icons/hicolor/512x512/apps/"
# A stale icon cache hides the new icon, so rebuild it where one exists.
if [ -f "$HOME/.local/share/icons/hicolor/icon-theme.cache" ] && command -v gtk-update-icon-cache >/dev/null; then
    gtk-update-icon-cache -q -f -t "$HOME/.local/share/icons/hicolor"
fi
