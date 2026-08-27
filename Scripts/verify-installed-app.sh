#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_APP="${1:-$PROJECT_DIR/Build/Lens.app}"
INSTALLED_APP="${2:-/Applications/Lens.app}"

for app_path in "$SOURCE_APP" "$INSTALLED_APP"; do
    if [[ ! -d "$app_path" ]]; then
        echo "Missing app bundle: $app_path" >&2
        exit 66
    fi
    if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist" 2>/dev/null || true)" != "app.lens.mac" ]]; then
        echo "Unexpected bundle identifier: $app_path" >&2
        exit 65
    fi
    codesign --verify --deep --strict --verbose=2 "$app_path"
done

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"
}

for key in CFBundleShortVersionString CFBundleVersion LensBuildChannel LensBuiltAt LensGitCommit; do
    source_value="$(plist_value "$SOURCE_APP" "$key")"
    installed_value="$(plist_value "$INSTALLED_APP" "$key")"
    if [[ "$source_value" != "$installed_value" ]]; then
        echo "Build metadata mismatch for $key: $source_value != $installed_value" >&2
        exit 65
    fi
done

SOURCE_EXECUTABLE="$SOURCE_APP/Contents/MacOS/Lens"
INSTALLED_EXECUTABLE="$INSTALLED_APP/Contents/MacOS/Lens"
SOURCE_SHA256="$(shasum -a 256 "$SOURCE_EXECUTABLE" | awk '{print $1}')"
INSTALLED_SHA256="$(shasum -a 256 "$INSTALLED_EXECUTABLE" | awk '{print $1}')"
if [[ "$SOURCE_SHA256" != "$INSTALLED_SHA256" ]]; then
    echo "Executable hash mismatch." >&2
    exit 65
fi

code_directory_hash() {
    codesign -d --verbose=4 "$1" 2>&1 | awk -F= '
        /^CandidateCDHash sha256=/ { candidate = $2 }
        /^CDHash=/ { fallback = $2 }
        END {
            if (candidate != "") print candidate
            else if (fallback != "") print fallback
        }
    '
}

SOURCE_CDHASH="$(code_directory_hash "$SOURCE_APP")"
INSTALLED_CDHASH="$(code_directory_hash "$INSTALLED_APP")"
if [[ -z "$SOURCE_CDHASH" || "$SOURCE_CDHASH" != "$INSTALLED_CDHASH" ]]; then
    echo "Code signature hash mismatch." >&2
    exit 65
fi

echo "Verified version: $(plist_value "$INSTALLED_APP" CFBundleShortVersionString) ($(plist_value "$INSTALLED_APP" CFBundleVersion))"
echo "Verified executable SHA-256: $INSTALLED_SHA256"
echo "Verified CDHash: $INSTALLED_CDHASH"
