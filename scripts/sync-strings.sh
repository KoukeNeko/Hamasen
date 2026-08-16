#!/bin/bash
# Brings the String Catalogs in line with the strings actually present in the
# source, using Xcode's own extractor rather than a hand-maintained list.
#
# The build emits one .stringsdata per source file; xcstringstool merges those
# into the catalog, adding new keys, marking removed ones stale, and writing
# format specifiers (%@, %lld) that are easy to get wrong by hand. Translations
# already in the catalog are preserved.
#
# Run this after adding or changing a user-visible string, then translate the
# new keys. --check reports drift instead of writing, for scripts/verify.sh.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="Hamasen"
CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

# The app target's catalog; the extension's action names are declared in its
# Info.plist rather than in source, so they are not extracted.
readonly CATALOG="$PROJECT_ROOT/Hamasen/Localizable.xcstrings"

resolve_developer_dir() {
    local selected
    selected="$(xcode-select -p 2>/dev/null || true)"
    if [[ "$selected" == *"/Xcode"*".app/"* ]]; then
        echo "$selected"
        return
    fi
    local xcode_app
    xcode_app="$(ls -d /Applications/Xcode*.app 2>/dev/null | sort -V | tail -1)"
    if [[ -z "$xcode_app" ]]; then
        echo "error: Xcode not found" >&2
        exit 1
    fi
    echo "$xcode_app/Contents/Developer"
}

export DEVELOPER_DIR="$(resolve_developer_dir)"

build_dir="$(xcodebuild -project "$PROJECT_ROOT/Hamasen.xcodeproj" -scheme "$SCHEME" \
    -configuration Debug -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ OBJROOT/ {print $2; exit}')"
if [[ -z "$build_dir" ]]; then
    echo "error: could not resolve the build directory" >&2
    exit 1
fi

echo "==> Building so the extractor runs"
xcodebuild -project "$PROJECT_ROOT/Hamasen.xcodeproj" -scheme "$SCHEME" \
    -configuration Debug -destination 'platform=macOS' \
    -allowProvisioningUpdates build | grep -E "error:|BUILD"

# Objects-normal holds one .stringsdata per compiled source file.
stringsdata_dir="$build_dir/Hamasen.build/Debug/Hamasen.build/Objects-normal/arm64"
if [[ ! -d "$stringsdata_dir" ]]; then
    echo "error: no extractor output at $stringsdata_dir" >&2
    exit 1
fi

if (( CHECK_ONLY )); then
    before="$(mktemp)"
    cp "$CATALOG" "$before"
fi

echo "==> Syncing $(basename "$CATALOG")"
xcrun xcstringstool sync "$CATALOG" --stringsdata "$stringsdata_dir"/*.stringsdata

if (( CHECK_ONLY )); then
    if ! diff -q "$before" "$CATALOG" >/dev/null; then
        cp "$before" "$CATALOG"
        rm -f "$before"
        echo "error: the String Catalog is out of date; run scripts/sync-strings.sh" >&2
        exit 1
    fi
    rm -f "$before"
    echo "==> String Catalog is up to date"
fi
