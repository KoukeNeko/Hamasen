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

# HamasenCore is a Swift package, and Xcode does not run its string extractor
# over package targets: `swift build -Xswiftc -emit-localized-strings` emits
# nothing for this target's own sources (only for its dependencies), verified
# on Xcode 27 beta 5. Until that works, the package's keys are read straight
# out of the uniform `String(localized: "…", bundle: .module)` call sites, so
# the catalog is still generated from the source rather than maintained by
# hand. Everything else — merging, format specifiers, staleness — is left to
# xcstringstool, exactly as for the app.
readonly PACKAGE_CATALOG="$PROJECT_ROOT/HamasenCore/Sources/HamasenCore/Localizable.xcstrings"

sync_package_catalog() {
    echo "==> Syncing HamasenCore's catalog"
    /usr/bin/python3 - "$PROJECT_ROOT/HamasenCore/Sources/HamasenCore" "$PACKAGE_CATALOG" <<'EOF'
import json, pathlib, re, sys

sources_root, catalog_path = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
# Matches the call sites and rewrites Swift interpolations into the format
# specifiers a catalog key uses, the way the compiler's extractor would.
call = re.compile(r'String\(localized: "((?:[^"\\]|\\.)*)"')
interpolation = re.compile(r'\\\(([^()]*(?:\([^()]*\))?[^()]*)\)')

def key_for(literal):
    # The compiler picks a specifier from the expression's type, which is not
    # visible here, so the names that are integers in this code base are
    # listed instead. A wrong guess is not cosmetic: the key stops matching
    # what the compiler emits and the string silently falls back to Chinese.
    def specifier(match):
        expression = match.group(1).strip()
        # Only a bare identifier can be judged by its name. Anything with a
        # call in it — Self.message(for: status) — is whatever that call
        # returns, which is not knowable here, so it stays %@.
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.]*", expression):
            return "%@"
        if re.search(r"count$|Count$", expression):
            return "%lld"
        if re.search(r"status$|Status$|code$|Code$", expression):
            return "%d"
        return "%@"
    return interpolation.sub(specifier, literal)

keys = []
for path in sorted(sources_root.rglob("*.swift")):
    for literal in call.findall(path.read_text()):
        key = key_for(literal)
        if key not in keys:
            keys.append(key)

catalog = json.loads(catalog_path.read_text())
strings = catalog.setdefault("strings", {})
for key in keys:
    strings.setdefault(key, {"extractionState": "manual", "localizations": {}})
for stale in set(strings) - set(keys):
    del strings[stale]
catalog["strings"] = {key: strings[key] for key in sorted(strings)}
catalog_path.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n")
print(f"    {len(keys)} keys")
EOF
}

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

sync_package_catalog
