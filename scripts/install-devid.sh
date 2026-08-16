#!/bin/zsh
# Builds Release, signs and notarizes everything with Developer ID, and
# installs to /Applications.
#
# Why this exists: distribution outside the Mac App Store needs a stable,
# Developer ID-signed and notarized build at a fixed path. The legacy "group.*"
# App Group is stripped here because under Developer ID it would demand a
# provisioning profile; migrated installs no longer need it.
set -euo pipefail

readonly PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
readonly SCHEME="Hamasen"
readonly INSTALL_PATH="/Applications/Hamasen.app"
readonly APP_BUNDLE_ID="dev.hamasen.mac"
readonly LEGACY_APP_GROUP="group.dev.hamasen.shared"
readonly FILE_PROVIDER_ID="dev.hamasen.mac.FileProvider"
readonly FILE_PROVIDER_RELATIVE_PATH="Contents/PlugIns/HamasenFileProvider.appex"
# Releases up to 1.0 shipped the Finder context menu as a FinderSync extension,
# in a nested helper app and, before that, directly in the app. The Finder menu
# now comes from the File Provider extension itself, but PluginKit and Launch
# Services keep registrations independently of what is on disk, so an upgrade
# has to retract those records or the removed bundles stay registered forever.
readonly RETIRED_HELPER_APP_RELATIVE_PATH="Contents/Applications/HamasenFinderHelper.app"
readonly RETIRED_HELPER_BUNDLE_ID="dev.hamasen.mac.FinderHelper"
readonly RETIRED_FINDER_SYNC_IDS=(
    "dev.hamasen.mac.FinderHelper.ContextMenu"
    "dev.hamasen.mac.ContextMenu"
)
readonly RETIRED_FINDER_SYNC_RELATIVE_PATHS=(
    "$RETIRED_HELPER_APP_RELATIVE_PATH/Contents/PlugIns/HamasenFinderSync.appex"
    "Contents/PlugIns/HamasenFinderSync.appex"
)
readonly TEAM_ID="33832Z66QU"
readonly LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
readonly NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-}"
readonly NOTARYTOOL_KEYCHAIN="${NOTARYTOOL_KEYCHAIN:-}"
readonly NOTARY_TIMEOUT="${NOTARY_TIMEOUT:-30m}"
readonly NOTARY_NO_S3_ACCELERATION="${NOTARY_NO_S3_ACCELERATION:-0}"

typeset -ga NOTARYTOOL_AUTH_ARGS=()
typeset -g WORK_DIR=""
typeset -g BACKUP_DIR=""
typeset -g BACKUP_PATH=""
typeset -g HAD_PREVIOUS_INSTALL=0
typeset -g INSTALLATION_STARTED=0
typeset -g INSTALLATION_SUCCEEDED=0

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

configure_notarytool_auth() {
    if [[ -z "$NOTARYTOOL_PROFILE" ]]; then
        echo "error: NOTARYTOOL_PROFILE is required" >&2
        echo "       Create one with 'xcrun notarytool store-credentials', then retry." >&2
        return 1
    fi
    if [[ "$NOTARY_NO_S3_ACCELERATION" != 0 && "$NOTARY_NO_S3_ACCELERATION" != 1 ]]; then
        echo "error: NOTARY_NO_S3_ACCELERATION must be 0 or 1" >&2
        return 1
    fi
    if [[ ! "$NOTARY_TIMEOUT" =~ '^[0-9]+([smh])?$' ]]; then
        echo "error: NOTARY_TIMEOUT must be an integer with an optional s, m, or h suffix" >&2
        return 1
    fi

    NOTARYTOOL_AUTH_ARGS=(--keychain-profile "$NOTARYTOOL_PROFILE")
    if [[ -n "$NOTARYTOOL_KEYCHAIN" ]]; then
        NOTARYTOOL_AUTH_ARGS+=(--keychain "$NOTARYTOOL_KEYCHAIN")
    fi
}

verify_required_tools() {
    local tool
    for tool in notarytool stapler; do
        if ! xcrun --find "$tool" >/dev/null 2>&1; then
            echo "error: xcrun could not find $tool in $DEVELOPER_DIR" >&2
            return 1
        fi
    done
    if [[ ! -x /usr/bin/syspolicy_check || ! -x /usr/sbin/spctl ]]; then
        echo "error: this macOS installation is missing syspolicy_check or spctl" >&2
        return 1
    fi
}

verify_notarytool_profile() {
    local history_output
    echo "==> Validating notarytool profile: $NOTARYTOOL_PROFILE"
    if ! history_output="$(xcrun notarytool history \
        "${NOTARYTOOL_AUTH_ARGS[@]}" \
        --output-format json --no-progress 2>&1)"; then
        echo "error: notarytool could not authenticate with the configured profile" >&2
        echo "$history_output" >&2
        return 1
    fi
}

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
        --timestamp --sign "$identity" --entitlements "$entitlements" "$bundle"
}

json_value() {
    local json_path=$1 key=$2
    /usr/bin/python3 - "$json_path" "$key" <<'PY'
import json, sys

try:
    with open(sys.argv[1], encoding="utf-8") as input_file:
        value = json.load(input_file).get(sys.argv[2], "")
except (OSError, ValueError, AttributeError):
    value = ""
print("" if value is None else value)
PY
}

run_syspolicy_check() {
    local subcommand=$1 bundle=$2 expected_message=$3
    local output command_status

    if output="$(/usr/bin/syspolicy_check "$subcommand" "$bundle" --verbose 2>&1)"; then
        command_status=0
    else
        command_status=$?
    fi
    echo "$output"

    # macOS 27 betas can return status 0 even when the report contains a Fatal
    # error, so the documented success sentence is the actual local gate.
    if [[ "$output" == *"$expected_message"* ]]; then
        return 0
    fi
    echo "warning: syspolicy_check $subcommand did not report success (exit $command_status)" >&2
    return 1
}

fetch_notary_log() {
    local submission_id=$1 work_dir=$2
    [[ -z "$submission_id" ]] && return 0

    local log_path="$work_dir/notary-log-$submission_id.json"
    echo "==> Fetching notarization log for $submission_id" >&2
    if xcrun notarytool log \
        "${NOTARYTOOL_AUTH_ARGS[@]}" \
        "$submission_id" "$log_path"; then
        cat "$log_path" >&2
    else
        echo "warning: notarization log was not available" >&2
    fi
}

notarize_and_validate() {
    local bundle=$1 work_dir=$2
    local archive_path="$work_dir/Hamasen-notarization.zip"
    local response_path="$work_dir/notary-submit.json"
    local error_path="$work_dir/notary-submit.stderr.log"
    local submission_id notary_status
    local -a transfer_options=()

    echo "==> Checking notarization submission readiness"
    if ! run_syspolicy_check \
        notary-submission "$bundle" \
        "App passed all pre-notarization checks and is ready for upload to the Apple notary service."; then
        echo "warning: continuing so the Apple notary service can provide the authoritative result" >&2
    fi

    echo "==> Creating notarization archive"
    ditto -c -k --keepParent "$bundle" "$archive_path"
    if [[ "$NOTARY_NO_S3_ACCELERATION" == 1 ]]; then
        transfer_options+=(--no-s3-acceleration)
    fi

    echo "==> Submitting for notarization (timeout: $NOTARY_TIMEOUT)"
    if ! xcrun notarytool submit \
        "${NOTARYTOOL_AUTH_ARGS[@]}" \
        --wait --timeout "$NOTARY_TIMEOUT" \
        --output-format json --no-progress \
        "${transfer_options[@]}" \
        "$archive_path" >"$response_path" 2>"$error_path"; then
        cat "$response_path" >&2
        cat "$error_path" >&2
        submission_id="$(json_value "$response_path" id)"
        fetch_notary_log "$submission_id" "$work_dir"
        echo "error: notarization submission failed; artifacts preserved at $work_dir" >&2
        return 1
    fi

    cat "$response_path"
    if [[ -s "$error_path" ]]; then
        cat "$error_path" >&2
    fi
    submission_id="$(json_value "$response_path" id)"
    notary_status="$(json_value "$response_path" status)"
    if [[ "$notary_status" != Accepted ]]; then
        fetch_notary_log "$submission_id" "$work_dir"
        echo "error: notarization status is '${notary_status:-unknown}', expected 'Accepted'" >&2
        echo "       Artifacts preserved at $work_dir" >&2
        return 1
    fi

    echo "==> Stapling and validating notarization ticket"
    xcrun stapler staple -v "$bundle"
    xcrun stapler validate -v "$bundle"
    codesign --verify --deep --strict "$bundle"

    echo "==> Checking distribution policy"
    if ! run_syspolicy_check \
        distribution "$bundle" \
        "App passed all pre-distribution checks and is ready for distribution."; then
        echo "error: the notarized app failed local distribution policy" >&2
        return 1
    fi
    /usr/sbin/spctl --assess --type execute --verbose=4 "$bundle"
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

verify_single_plugin_registration() {
    local identifier=$1 expected_path=$2 records registered_path path_count
    records="$(pluginkit -m -A -D -vvv -i "$identifier")"
    registered_path="$(awk -F' = ' '/^[[:space:]]*Path = / {print $2}' <<< "$records")"
    path_count="$(awk '/^[[:space:]]*Path = / {count++} END {print count + 0}' <<< "$records")"

    if [[ "$path_count" != 1 || "$registered_path" != "$expected_path" ]]; then
        echo "error: expected exactly one $identifier registration at $expected_path" >&2
        echo "$records" >&2
        return 1
    fi
}

registered_app_paths_for_identifier() {
    local bundle_identifier=$1
    local registry_paths_file registry_dump_status
    registry_paths_file="$(mktemp)"
    # lsregister writes its database dump to stderr on current macOS releases.
    # Read it directly from Python so no downstream process closes the pipe
    # early and leaves lsregister blocked on a full output buffer.
    set +e
    "$LSREGISTER" -dump 2>&1 \
        | WANTED_BUNDLE_ID="$bundle_identifier" /usr/bin/python3 -c '
import os
import re
import sys

wanted = os.environ["WANTED_BUNDLE_ID"]
path = None
identifier = None

def emit():
    if identifier == wanted and path:
        print(path)

for line in sys.stdin:
    if line.startswith("--------------------"):
        emit()
        path = None
        identifier = None
    elif line.startswith("path:"):
        value = line.split(":", 1)[1].strip()
        path = re.sub(r"\s+\(0x[0-9A-Fa-f]+\)$", "", value)
    elif line.startswith("identifier:"):
        identifier = line.split(":", 1)[1].strip()
emit()
' > "$registry_paths_file"
    registry_dump_status=$pipestatus[1]
    set -e
    if (( registry_dump_status != 0 )); then
        rm -f "$registry_paths_file"
        echo "error: could not read the Launch Services registry" >&2
        return 1
    fi
    cat "$registry_paths_file"
    rm -f "$registry_paths_file"
}

unregister_app_copy() {
    local app_path=$1
    [[ "$app_path" == "$INSTALL_PATH" ]] && return
    pluginkit -r "$app_path/$FILE_PROVIDER_RELATIVE_PATH" 2>/dev/null || true
    unregister_retired_finder_sync "$app_path"
    "$LSREGISTER" -u "$app_path" 2>/dev/null || true
}

# Retracts the records left by the retired FinderSync bundles. Their paths must
# still resolve for PluginKit to accept the removal, so this runs before the
# installed app is replaced.
unregister_retired_finder_sync() {
    local app_path=$1 relative_path
    for relative_path in "${RETIRED_FINDER_SYNC_RELATIVE_PATHS[@]}"; do
        pluginkit -r "$app_path/$relative_path" 2>/dev/null || true
    done
    "$LSREGISTER" -u "$app_path/$RETIRED_HELPER_APP_RELATIVE_PATH" 2>/dev/null || true
}

verify_no_plugin_registration() {
    local identifier=$1 records path_count
    records="$(pluginkit -m -A -D -vvv -i "$identifier")"
    path_count="$(awk '/^[[:space:]]*Path = / {count++} END {print count + 0}' <<< "$records")"
    if [[ "$path_count" != 0 ]]; then
        echo "error: expected no remaining $identifier registrations" >&2
        echo "$records" >&2
        return 1
    fi
}

verify_no_app_registration() {
    local identifier=$1 registered_paths path_count
    registered_paths="$(registered_app_paths_for_identifier "$identifier")"
    path_count="$(awk 'NF {count++} END {print count + 0}' <<< "$registered_paths")"

    if [[ "$path_count" != 0 ]]; then
        echo "error: expected no remaining $identifier registrations" >&2
        echo "$registered_paths" >&2
        return 1
    fi
}

verify_single_app_registration() {
    local identifier=$1 expected_path=$2 registered_paths path_count
    registered_paths="$(registered_app_paths_for_identifier "$identifier")"
    path_count="$(awk 'NF {count++} END {print count + 0}' <<< "$registered_paths")"

    if [[ "$path_count" != 1 || "$registered_paths" != "$expected_path" ]]; then
        echo "error: expected exactly one $identifier registration at $expected_path" >&2
        echo "$registered_paths" >&2
        return 1
    fi
}

register_stable_install() {
    local index relative_path finder_sync_id
    [[ -d "$INSTALL_PATH" ]] || return 0

    "$LSREGISTER" -f "$INSTALL_PATH"
    if [[ -d "$INSTALL_PATH/$FILE_PROVIDER_RELATIVE_PATH" ]]; then
        pluginkit -a "$INSTALL_PATH/$FILE_PROVIDER_RELATIVE_PATH"
    fi
    # Rollback may restore a release whose context menu was a FinderSync
    # extension; re-register it so rollback restores the menu, not merely the
    # app bundle.
    if [[ -d "$INSTALL_PATH/$RETIRED_HELPER_APP_RELATIVE_PATH" ]]; then
        "$LSREGISTER" -f "$INSTALL_PATH/$RETIRED_HELPER_APP_RELATIVE_PATH"
    fi
    for index in {1..${#RETIRED_FINDER_SYNC_RELATIVE_PATHS[@]}}; do
        relative_path="${RETIRED_FINDER_SYNC_RELATIVE_PATHS[$index]}"
        finder_sync_id="${RETIRED_FINDER_SYNC_IDS[$index]}"
        [[ -d "$INSTALL_PATH/$relative_path" ]] || continue
        pluginkit -a "$INSTALL_PATH/$relative_path"
        sleep 2
        pluginkit -e use -p com.apple.FinderSync -i "$finder_sync_id"
    done
}

restore_previous_install() {
    echo "==> Restoring previous installation" >&2
    pkill -x Hamasen 2>/dev/null || true
    if [[ -x "$INSTALL_PATH/Contents/MacOS/Hamasen" ]]; then
        "$INSTALL_PATH/Contents/MacOS/Hamasen" --rollback-uncommitted-credentials || \
            echo "warning: could not remove uncommitted migrated credentials" >&2
    fi
    pluginkit -r "$INSTALL_PATH/$FILE_PROVIDER_RELATIVE_PATH" 2>/dev/null || true
    unregister_retired_finder_sync "$INSTALL_PATH"
    "$LSREGISTER" -u "$INSTALL_PATH" 2>/dev/null || true
    rm -rf "$INSTALL_PATH"

    if (( HAD_PREVIOUS_INSTALL )); then
        if ! ditto "$BACKUP_PATH" "$INSTALL_PATH"; then
            echo "error: automatic restore failed; backup preserved at $BACKUP_PATH" >&2
            return 1
        fi
        killall pkd 2>/dev/null || true
        sleep 3
        if ! register_stable_install; then
            echo "error: previous app was restored but could not be re-registered" >&2
            return 1
        fi
        echo "==> Previous installation restored and re-registered" >&2
    else
        echo "==> Removed failed installation; there was no previous app to restore" >&2
    fi
}

handle_exit() {
    local exit_status=$?
    trap - EXIT
    set +e

    if (( exit_status != 0 )); then
        if (( INSTALLATION_STARTED && ! INSTALLATION_SUCCEEDED )); then
            restore_previous_install
        fi
        if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
            echo "==> Staging and notarization artifacts preserved at $WORK_DIR" >&2
        fi
        if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
            echo "==> Installation backup preserved at $BACKUP_DIR" >&2
        fi
    fi
    exit "$exit_status"
}

trap handle_exit EXIT

main() {
    local identity staging products_dir work_dir
    local products_root build_app registered_app existing_app_paths
    local retired_finder_sync_id

    configure_notarytool_auth
    verify_required_tools
    verify_notarytool_profile

    identity="$(find_developer_id_identity)"
    if [[ -z "$identity" ]]; then
        echo "error: no Developer ID Application identity in the keychain" >&2
        return 1
    fi
    echo "==> Signing identity: $identity"
    echo "==> Using DEVELOPER_DIR: $DEVELOPER_DIR"

    build_release
    products_dir="$(built_products_dir)"

    WORK_DIR="$(mktemp -d)"
    work_dir="$WORK_DIR"
    staging="$work_dir/Hamasen.app"
    ditto "$products_dir/Hamasen.app" "$staging"

    echo "==> Preparing distribution entitlements"
    write_distribution_entitlements \
        "$PROJECT_DIR/Config/Hamasen.entitlements" "$work_dir/app.entitlements"
    write_distribution_entitlements \
        "$PROJECT_DIR/Config/HamasenFileProvider.entitlements" "$work_dir/provider.entitlements"

    echo "==> Signing (inner bundles first)"
    sign_bundle "$identity" "$work_dir/provider.entitlements" \
        "$staging/$FILE_PROVIDER_RELATIVE_PATH"
    sign_bundle "$identity" "$work_dir/app.entitlements" "$staging"
    codesign --verify --deep --strict "$staging"
    verify_no_restricted_keychain_access "$staging"
    verify_no_restricted_keychain_access "$staging/$FILE_PROVIDER_RELATIVE_PATH"
    notarize_and_validate "$staging" "$work_dir"

    echo "==> Installing to $INSTALL_PATH"
    BACKUP_DIR="$(mktemp -d)"
    BACKUP_PATH="$BACKUP_DIR/Hamasen.app"
    if [[ -d "$INSTALL_PATH" ]]; then
        ditto "$INSTALL_PATH" "$BACKUP_PATH"
        HAD_PREVIOUS_INSTALL=1
    fi
    INSTALLATION_STARTED=1
    pkill -x Hamasen 2>/dev/null || true
    unregister_retired_finder_sync "$INSTALL_PATH"
    rm -rf "$INSTALL_PATH"
    ditto "$staging" "$INSTALL_PATH"

    echo "==> Verifying installed notarization and distribution policy"
    codesign --verify --deep --strict "$INSTALL_PATH"
    xcrun stapler validate -v "$INSTALL_PATH"
    if ! run_syspolicy_check \
        distribution "$INSTALL_PATH" \
        "App passed all pre-distribution checks and is ready for distribution."; then
        echo "error: installed app failed local distribution policy" >&2
        return 1
    fi
    /usr/sbin/spctl --assess --type execute --verbose=4 "$INSTALL_PATH"

    # Clean up a partial two-phase migration left by an interrupted prior run
    # before the development-signed helper starts a new transaction.
    if ! "$INSTALL_PATH/Contents/MacOS/Hamasen" --rollback-uncommitted-credentials; then
        echo "error: could not clean up an uncommitted credential migration" >&2
        return 1
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
        return 1
    fi

    echo "==> Verifying installed credential access"
    if ! "$INSTALL_PATH/Contents/MacOS/Hamasen" \
        --verify-credentials-only; then
        echo "error: installed app cannot read migrated credentials; restoring previous install" >&2
        "$INSTALL_PATH/Contents/MacOS/Hamasen" --rollback-uncommitted-credentials || \
            echo "warning: could not remove uncommitted migrated credentials" >&2
        return 1
    fi

    echo "==> Registering"
    # Building leaves a development-signed copy of the app registered from
    # DerivedData. Remove its extension and the app itself so Finder and
    # fileproviderd select only /Applications.
    products_root="$(dirname "$products_dir")"
    for configuration in Debug Release; do
        build_app="$products_root/$configuration/Hamasen.app"
        unregister_app_copy "$build_app"
    done
    existing_app_paths="$(registered_app_paths_for_identifier "$APP_BUNDLE_ID")"
    while IFS= read -r registered_app; do
        [[ -z "$registered_app" ]] && continue
        unregister_app_copy "$registered_app"
    done <<< "$existing_app_paths"
    # The explicit removal above covers the current build root even when
    # Launch Services has not indexed it yet; the registry pass also catches
    # clones left in older DerivedData roots.
    killall pkd 2>/dev/null || true
    sleep 3
    "$LSREGISTER" -f "$INSTALL_PATH"
    pluginkit -a "$INSTALL_PATH/$FILE_PROVIDER_RELATIVE_PATH"
    sleep 2

    verify_single_plugin_registration \
        "$FILE_PROVIDER_ID" \
        "$INSTALL_PATH/$FILE_PROVIDER_RELATIVE_PATH"
    for retired_finder_sync_id in "${RETIRED_FINDER_SYNC_IDS[@]}"; do
        verify_no_plugin_registration "$retired_finder_sync_id"
    done
    verify_single_app_registration "$APP_BUNDLE_ID" "$INSTALL_PATH"
    verify_no_app_registration "$RETIRED_HELPER_BUNDLE_ID"

    echo "==> Finalizing credential migration"
    if ! "$INSTALL_PATH/Contents/MacOS/Hamasen" \
        --verify-credentials-only --finalize-migration; then
        echo "error: could not finalize credential migration" >&2
        return 1
    fi

    open "$INSTALL_PATH"
    INSTALLATION_SUCCEEDED=1
    rm -rf "$BACKUP_DIR"
    rm -rf "$WORK_DIR"
    echo "==> Done"
}

main "$@"
