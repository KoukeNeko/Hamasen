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

echo "==> [1/4] Checking every target declares the same build number"
# An archive is refused when an extension's build number differs from the app
# around it, and they have differed three times: bumping the version in
# Xcode's General tab writes it to one target, leaving the rest behind. The
# numbers are read straight out of the project file — asking xcodebuild costs
# fifteen seconds to compare two integers.
declared_versions="$(grep -oE 'CURRENT_PROJECT_VERSION = [^;]+;' \
    "${PROJECT_ROOT}/Hamasen.xcodeproj/project.pbxproj" | sort -u)"
if [[ "$(printf '%s\n' "$declared_versions" | wc -l | tr -d ' ')" != "1" ]]; then
    echo "error: the project declares more than one build number:" >&2
    printf '%s\n' "$declared_versions" | sed 's/^/       /' >&2
    echo "       They must agree, or the archive is refused." >&2
    exit 1
fi
echo "    ${declared_versions}"

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
