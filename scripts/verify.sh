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

echo "==> [1/3] Linting extension Info.plists"
plutil -lint "${PROJECT_ROOT}"/Config/*Info.plist

echo "==> [2/3] Running HamasenCore tests"
(cd "${PROJECT_ROOT}/HamasenCore" && swift test)

echo "==> [3/3] Building app + File Provider extension"
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
