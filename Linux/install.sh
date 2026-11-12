#!/bin/sh
# Installs a launcher for the current user that points at this checkout.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
chmod +x "$dir/hamasen.py"
mkdir -p "$HOME/.local/share/applications"
sed "s|HAMASEN_DIR|$dir|" "$dir/app.hamasen.Hamasen.desktop" > "$HOME/.local/share/applications/app.hamasen.Hamasen.desktop"
