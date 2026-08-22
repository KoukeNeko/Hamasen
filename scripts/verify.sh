#!/bin/bash
# Verification harness for Hamasen.
#
# 1. Lints the extension Info.plists (the Finder context menu is declared there).
# 2. Runs the HamasenCore test suite (hermetic, in-process SFTP server).
# 3. Builds the app + File Provider extension with xcodebuild.
#
# Exits non-zero on the first failure.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="Hamasen"

resolve_developer_dir() {
    local selected
    selected="$(xcode-select -p 2>/dev/null || true)"
    if [[ "$selected" == *"/Xcode"*".app/"* ]]; then
        echo "${selected}"
        return
    fi
    local xcode_app
    xcode_app="$(ls -d /Applications/Xcode*.app 2>/dev/null | sort -V | tail -1)"
    if [[ -z "$xcode_app" ]]; then
        echo "error: Xcode not found" >&2
        exit 1
    fi
    echo "${xcode_app}/Contents/Developer"
}

DEVELOPER_DIR="$(resolve_developer_dir)"
export DEVELOPER_DIR

echo "==> Using DEVELOPER_DIR: ${DEVELOPER_DIR}"

echo "==> [1/4] Checking the app and its extension agree on a version"
# Xcode writes a version bumped in its General tab to the target, not the
# project, so the two drift apart whenever one is changed there — and an
# archive is refused outright when they disagree. Structure did not stop
# this happening three times; noticing it here does.
app_version="$(xcodebuild -project "${PROJECT_ROOT}/Hamasen.xcodeproj" -target Hamasen \
    -showBuildSettings 2>/dev/null | awk -F' = ' '/ CURRENT_PROJECT_VERSION/ {print $2; exit}')"
extension_version="$(xcodebuild -project "${PROJECT_ROOT}/Hamasen.xcodeproj" -target HamasenFileProvider \
    -showBuildSettings 2>/dev/null | awk -F' = ' '/ CURRENT_PROJECT_VERSION/ {print $2; exit}')"
if [[ "$app_version" != "$extension_version" ]]; then
    echo "error: the app is build ${app_version} and its extension is build ${extension_version}" >&2
    echo "       They must match, or the archive is refused." >&2
    exit 1
fi
echo "    both are build ${app_version}"

echo "==> [2/4] Linting extension Info.plists"
plutil -lint "${PROJECT_ROOT}"/Config/*Info.plist

echo "==> [3/4] Running HamasenCore tests"
(cd "${PROJECT_ROOT}/HamasenCore" && swift test)

echo "==> [4/4] Building app + File Provider extension"
# pipefail (set above) carries xcodebuild's exit status through the grep, so a
# failed build fails the script instead of being swallowed.
xcodebuild \
    -project "${PROJECT_ROOT}/Hamasen.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration Debug \
    -destination 'platform=macOS' \
    -allowProvisioningUpdates \
    build | grep -E "error:|warning:|BUILD"

echo "==> All checks passed"
