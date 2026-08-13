#!/bin/zsh
# Builds Release, signs everything with Developer ID, and installs to
# /Applications.
#
# Why this exists: pkd only enables the FinderSync extension (the Finder
# context menu) for apps whose entire bundle chain is Developer ID-signed —
# development-signed builds are silently flipped to "ignored". Notarization
# is not required for local use. The legacy "group.*" App Group is stripped
# here because under Developer ID it would demand a provisioning profile;
# migrated installs no longer need it.
set -euo pipefail

readonly PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
readonly SCHEME="Hamasen"
readonly INSTALL_PATH="/Applications/Hamasen.app"
readonly LEGACY_APP_GROUP="group.dev.hamasen.shared"
readonly FINDER_SYNC_ID="dev.hamasen.mac.ContextMenu"
readonly TEAM_ID="33832Z66QU"
readonly LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

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

find_developer_id_identity() {
    security find-identity -v -p codesigning \
        | awk -F'"' -v team="($TEAM_ID)" '$2 ~ /^Developer ID Application:/ && $2 ~ team {print $1; exit}' \
        | awk '{print $2}'
}

build_release() {
    echo "==> Building Release"
    xcodebuild \
        -project "$PROJECT_DIR/Hamasen.xcodeproj" \
        -scheme "$SCHEME" -configuration Release \
        -destination 'platform=macOS' \
        -allowProvisioningUpdates build \
        | grep -E "error:|BUILD"
}

built_products_dir() {
    xcodebuild \
        -project "$PROJECT_DIR/Hamasen.xcodeproj" \
        -scheme "$SCHEME" -configuration Release -showBuildSettings 2>/dev/null \
        | awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $2; exit}'
}

# Copies an entitlements file, dropping the legacy App Group entry that only
# development builds may carry.
write_distribution_entitlements() {
    local source_plist=$1 output_plist=$2
    /usr/bin/python3 - "$source_plist" "$output_plist" "$LEGACY_APP_GROUP" <<'PY'
import plistlib, sys
source_path, output_path, legacy_group = sys.argv[1:4]
with open(source_path, "rb") as source_file:
    entitlements = plistlib.load(source_file)
groups_key = "com.apple.security.application-groups"
if groups_key in entitlements:
    entitlements[groups_key] = [
        group for group in entitlements[groups_key] if group != legacy_group
    ]
# Data Protection Keychain sharing is a restricted entitlement and needs a
# distribution provisioning profile. The Developer ID build instead uses
# file-based Keychain ACLs, so carrying this key would make AMFI reject it.
entitlements.pop("keychain-access-groups", None)
with open(output_path, "wb") as output_file:
    plistlib.dump(entitlements, output_file)
PY
}

sign_bundle() {
    local identity=$1 entitlements=$2 bundle=$3
    rm -f "$bundle/Contents/embedded.provisionprofile"
    codesign --force --options runtime \
        --sign "$identity" --entitlements "$entitlements" "$bundle"
}

verify_no_restricted_keychain_access() {
    local bundle=$1
    if codesign -d --entitlements :- "$bundle" 2>/dev/null \
        | /usr/bin/python3 -c '
import plistlib, sys
entitlements = plistlib.loads(sys.stdin.buffer.read())
sys.exit(0 if "keychain-access-groups" in entitlements else 1)
'; then
        echo "error: $bundle still has restricted Keychain access groups" >&2
        exit 1
    fi
}

main() {
    local identity
    identity="$(find_developer_id_identity)"
    if [[ -z "$identity" ]]; then
        echo "error: no Developer ID Application identity in the keychain" >&2
        exit 1
    fi
    echo "==> Signing identity: $identity"
    echo "==> Using DEVELOPER_DIR: $DEVELOPER_DIR"

    build_release
    local staging products_dir
    products_dir="$(built_products_dir)"

    staging="$(mktemp -d)/Hamasen.app"
    ditto "$products_dir/Hamasen.app" "$staging"

    echo "==> Preparing distribution entitlements"
    local work_dir
    work_dir="$(dirname "$staging")"
    write_distribution_entitlements \
        "$PROJECT_DIR/Config/Hamasen.entitlements" "$work_dir/app.entitlements"
    write_distribution_entitlements \
        "$PROJECT_DIR/Config/HamasenFileProvider.entitlements" "$work_dir/provider.entitlements"

    echo "==> Signing (inner bundles first)"
    sign_bundle "$identity" "$PROJECT_DIR/Config/HamasenFinderSync.entitlements" \
        "$staging/Contents/PlugIns/HamasenFinderSync.appex"
    sign_bundle "$identity" "$work_dir/provider.entitlements" \
        "$staging/Contents/PlugIns/HamasenFileProvider.appex"
    sign_bundle "$identity" "$work_dir/app.entitlements" "$staging"
    codesign --verify --deep --strict "$staging"
    verify_no_restricted_keychain_access "$staging"
    verify_no_restricted_keychain_access "$staging/Contents/PlugIns/HamasenFileProvider.appex"

    echo "==> Installing to $INSTALL_PATH"
    local backup_dir backup_path had_previous_install
    backup_dir="$(mktemp -d)"
    backup_path="$backup_dir/Hamasen.app"
    had_previous_install=false
    if [[ -d "$INSTALL_PATH" ]]; then
        ditto "$INSTALL_PATH" "$backup_path"
        had_previous_install=true
    fi
    pkill -x Hamasen 2>/dev/null || true
    rm -rf "$INSTALL_PATH"
    ditto "$staging" "$INSTALL_PATH"

    # Clean up a partial two-phase migration left by an interrupted prior run
    # before the development-signed helper starts a new transaction.
    if ! "$INSTALL_PATH/Contents/MacOS/Hamasen" --rollback-uncommitted-credentials; then
        echo "error: could not clean up an uncommitted credential migration" >&2
        rm -rf "$INSTALL_PATH"
        if [[ "$had_previous_install" == true ]]; then
            ditto "$backup_path" "$INSTALL_PATH"
        fi
        rm -rf "$backup_dir"
        rm -rf "$(dirname "$staging")"
        exit 1
    fi

    # The development-signed helper can still read every migration-era Data
    # Protection Keychain group. The final app must already be at its stable
    # path so SecTrustedApplication can record the correct code identity.
    echo "==> Migrating legacy shared data"
    if ! "$products_dir/Hamasen.app/Contents/MacOS/Hamasen" \
        --migrate-legacy-group-only "$INSTALL_PATH"; then
        echo "error: credential migration failed; restoring previous install" >&2
        "$INSTALL_PATH/Contents/MacOS/Hamasen" --rollback-uncommitted-credentials || \
            echo "warning: could not remove uncommitted migrated credentials" >&2
        rm -rf "$INSTALL_PATH"
        if [[ "$had_previous_install" == true ]]; then
            ditto "$backup_path" "$INSTALL_PATH"
        fi
        rm -rf "$backup_dir"
        rm -rf "$(dirname "$staging")"
        exit 1
    fi

    echo "==> Verifying installed credential access"
    if ! "$INSTALL_PATH/Contents/MacOS/Hamasen" \
        --verify-credentials-only --finalize-migration; then
        echo "error: installed app cannot read migrated credentials; restoring previous install" >&2
        "$INSTALL_PATH/Contents/MacOS/Hamasen" --rollback-uncommitted-credentials || \
            echo "warning: could not remove uncommitted migrated credentials" >&2
        rm -rf "$INSTALL_PATH"
        if [[ "$had_previous_install" == true ]]; then
            ditto "$backup_path" "$INSTALL_PATH"
        fi
        rm -rf "$backup_dir"
        rm -rf "$(dirname "$staging")"
        exit 1
    fi

    rm -rf "$backup_dir"
    rm -rf "$(dirname "$staging")"

    echo "==> Registering"
    # Building leaves development-signed copies registered from DerivedData;
    # pkd refuses to enable a FinderSync identifier while any registration of
    # it fails validation, and its in-memory record of the replaced install
    # path goes stale — so drop the duplicates and restart pkd before
    # electing. Elections must target exactly one, Developer ID-signed copy.
    for configuration in Debug Release; do
        pluginkit -r "$(dirname "$products_dir")/$configuration/Hamasen.app/Contents/PlugIns/HamasenFinderSync.appex" 2>/dev/null || true
    done
    killall pkd 2>/dev/null || true
    sleep 3
    "$LSREGISTER" -f "$INSTALL_PATH"
    pluginkit -a "$INSTALL_PATH/Contents/PlugIns/HamasenFinderSync.appex"
    sleep 2
    pluginkit -e use -i "$FINDER_SYNC_ID"
    sleep 2

    echo "==> FinderSync status (enabled is '+'):"
    local finder_sync_status
    finder_sync_status="$(pluginkit -m -A -D -i "$FINDER_SYNC_ID")"
    echo "$finder_sync_status"
    if ! grep -q '^[[:space:]]*+' <<< "$finder_sync_status"; then
        echo "warning: FinderSync is installed but macOS has not enabled it." >&2
        echo "         Enable Hamasen in System Settings > General > Login Items & Extensions > Finder." >&2
    fi
    open "$INSTALL_PATH"
    echo "==> Done"
}

main "$@"
