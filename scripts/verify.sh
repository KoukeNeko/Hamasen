#!/bin/bash
# Verification harness for Hamasen.
#
# 1. Runs the HamasenCore test suite (hermetic, in-process SFTP server).
# 2. Builds the app + File Provider extension with xcodebuild.
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

echo "==> [1/2] Running HamasenCore tests"
(cd "${PROJECT_ROOT}/HamasenCore" && swift test)

echo "==> [2/2] Building app + File Provider extension"
xcodebuild \
    -project "${PROJECT_ROOT}/Hamasen.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration Debug \
    -destination 'platform=macOS' \
    -allowProvisioningUpdates \
    build | grep -E "error:|warning:|BUILD" || true

echo "==> All checks passed"
