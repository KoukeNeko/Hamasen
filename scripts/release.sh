#!/bin/bash
# Packages a notarized Hamasen.app into the archive a GitHub release ships,
# and refuses to package one that a downloader could not open.
#
# Notarization is not done here: it is done from Xcode's Organizer, whose
# credentials belong to the Apple ID signed into Xcode rather than to a
# notarytool keychain profile. What this checks is the result of that —
# a stapled ticket and a Gatekeeper verdict — because a release that fails
# either is worse than no release: it looks installable and is not.
#
#   scripts/release.sh <path-to-notarized-Hamasen.app> <tag>
#
# Publishing is a separate, deliberate step; this only writes the archive
# and prints what to check.
set -euo pipefail

readonly APP_PATH="${1:-}"
readonly TAG="${2:-}"
readonly TEAM_ID="33832Z66QU"
readonly OUTPUT_DIR="${PROJECT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/dist"

usage() {
    echo "usage: scripts/release.sh <path-to-notarized-Hamasen.app> <tag>" >&2
    exit 2
}

[[ -n "$APP_PATH" && -n "$TAG" ]] || usage
[[ -d "$APP_PATH" ]] || { echo "error: no app bundle at $APP_PATH" >&2; exit 1; }

verify_signature() {
    echo "==> Signature"
    codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1 | sed 's/^/    /'
    # Read once, then parse: an awk that exits on the first match closes the
    # pipe under codesign, and pipefail turns that SIGPIPE into a failure.
    local description authority
    description="$(codesign -dvv "$APP_PATH" 2>&1 || true)"
    authority="$(printf '%s\n' "$description" | grep -m1 '^Authority=Developer ID Application' | cut -d= -f2-)"
    if [[ -z "$authority" ]]; then
        echo "error: not signed with a Developer ID Application certificate" >&2
        exit 1
    fi
    if [[ "$authority" != *"($TEAM_ID)"* ]]; then
        echo "error: signed by $authority, which is not team $TEAM_ID" >&2
        exit 1
    fi
    echo "    $authority"
}

verify_notarization() {
    echo "==> Notarization"
    # A stapled ticket is what lets the first launch work without the network;
    # without it the app is only notarized for a Mac that can reach Apple.
    if ! xcrun stapler validate "$APP_PATH" >/dev/null 2>&1; then
        echo "error: no stapled notarization ticket" >&2
        echo "       Notarize in Xcode's Organizer (Distribute App → Developer ID)," >&2
        echo "       export the app, and point this script at the exported copy." >&2
        exit 1
    fi
    echo "    stapled"

    # The verdict a downloader's Mac reaches, asked the same way theirs will.
    local assessment
    if ! assessment="$(spctl --assess --type execute --verbose=4 "$APP_PATH" 2>&1)"; then
        echo "error: Gatekeeper would reject this build" >&2
        echo "$assessment" | sed 's/^/    /' >&2
        exit 1
    fi
    echo "$assessment" | sed 's/^/    /'
}

verify_file_provider_declaration() {
    echo "==> File Provider extension"
    local info="$APP_PATH/Contents/PlugIns/HamasenFileProvider.appex/Contents/Info.plist"
    [[ -f "$info" ]] || { echo "error: the extension is missing from the bundle" >&2; exit 1; }
    local group
    group="$(plutil -extract NSExtension.NSExtensionFileProviderDocumentGroup raw "$info" 2>/dev/null || true)"
    if [[ -z "$group" ]]; then
        echo "error: the extension does not declare its document group" >&2
        exit 1
    fi
    echo "    document group: $group"

    # The app and its extension are one product but two bundles, each with
    # its own minimum. An app that launches on a system its extension will
    # not load on is worse than one that refuses to launch: Finder simply
    # shows nothing, with nothing to explain it.
    local app_minimum extension_minimum
    app_minimum="$(plutil -extract LSMinimumSystemVersion raw "$APP_PATH/Contents/Info.plist")"
    extension_minimum="$(plutil -extract LSMinimumSystemVersion raw "$info")"
    if [[ "$app_minimum" != "$extension_minimum" ]]; then
        echo "error: the app requires macOS $app_minimum but its extension requires $extension_minimum" >&2
        echo "       Set MACOSX_DEPLOYMENT_TARGET once, at the project level." >&2
        exit 1
    fi
    echo "    both bundles require macOS $app_minimum"
}

package() {
    mkdir -p "$OUTPUT_DIR"
    local archive="$OUTPUT_DIR/Hamasen-$TAG.zip"
    rm -f "$archive"
    # ditto rather than zip: it is what preserves the bundle's symlinks and
    # extended attributes, and the signature is checked over both.
    ditto -c -k --keepParent "$APP_PATH" "$archive"
    echo "==> Wrote $archive ($(du -h "$archive" | cut -f1))"
    echo "$archive"
}

verify_signature
verify_notarization
verify_file_provider_declaration
package >/dev/null
echo "==> Ready. Publish with:"
echo "    gh release create $TAG dist/Hamasen-$TAG.zip --prerelease --title ... --notes-file ..."
