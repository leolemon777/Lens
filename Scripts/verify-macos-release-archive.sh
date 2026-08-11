#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODE_FLAG=()

if [[ "${1:-}" == "--development" ]]; then
    MODE_FLAG=(--development)
    shift
fi
if [[ $# -ne 1 ]]; then
    echo "Usage: $0 [--development] <release-archive-directory>" >&2
    exit 64
fi

[[ -d "$1" && ! -L "$1" ]] \
    || { echo "Release archive must be a regular directory: $1" >&2; exit 66; }
ARCHIVE_DIR="$(cd "$1" && pwd)"

fail() {
    echo "release archive verification failed: $1" >&2
    exit 65
}

safe_filename() {
    local filename="$1"
    [[ -n "$filename" && "$filename" != */* && "$filename" != "." && "$filename" != ".." ]]
}

metadata_count="$(find "$ARCHIVE_DIR" -mindepth 1 -maxdepth 1 -type f -name 'ScreenTrace-*-archive.json' | wc -l | tr -d ' ')"
[[ "$metadata_count" -eq 1 ]] || fail "expected exactly one archive metadata file"
METADATA_PATH="$(find "$ARCHIVE_DIR" -mindepth 1 -maxdepth 1 -type f -name 'ScreenTrace-*-archive.json' -print -quit)"

metadata_value() {
    plutil -extract "$1" raw "$METADATA_PATH"
}

[[ "$(metadata_value schemaVersion)" == "1" ]] || fail "unsupported archive metadata schema"
[[ "$(metadata_value product)" == "ScreenTrace" ]] || fail "unexpected archived product"
APP_VERSION="$(metadata_value version)"
BUILD_NUMBER="$(metadata_value buildNumber)"
RELEASE_CHANNEL="$(metadata_value releaseChannel)"
GIT_COMMIT="$(metadata_value gitCommit)"
MACHO_UUID="$(metadata_value machOUUID)"
RELEASE_MANIFEST_FILENAME="$(metadata_value releaseManifest)"
ARTIFACT_NAME="ScreenTrace-$APP_VERSION-$BUILD_NUMBER"
ARCHIVE_METADATA_FILENAME="$ARTIFACT_NAME-archive.json"
ARCHIVE_CHECKSUMS_FILENAME="$ARTIFACT_NAME-ARCHIVE_SHA256SUMS.txt"
RELEASE_CHECKSUMS_FILENAME="$ARTIFACT_NAME-SHA256SUMS.txt"
RELEASE_NOTES_FILENAME="$ARTIFACT_NAME-RELEASE_NOTES.md"

[[ "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || fail "invalid archived version"
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || fail "invalid archived build number"
[[ "$GIT_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "invalid archived Git commit"
[[ "$MACHO_UUID" =~ ^[0-9A-F-]{36}$ ]] || fail "invalid archived Mach-O UUID"
case "$RELEASE_CHANNEL" in
    alpha|beta|stable) ;;
    *) fail "invalid archived release channel" ;;
esac
[[ "$(basename "$METADATA_PATH")" == "$ARCHIVE_METADATA_FILENAME" ]] \
    || fail "archive metadata filename does not match its identity"
[[ "$RELEASE_MANIFEST_FILENAME" == "$ARTIFACT_NAME-release.json" ]] \
    || fail "archive metadata references an unexpected release manifest"

EXPECTED_FILES=(
    "$ARTIFACT_NAME.dmg"
    "$ARTIFACT_NAME.app.zip"
    "$ARTIFACT_NAME.dSYM.zip"
    "$RELEASE_MANIFEST_FILENAME"
    "$RELEASE_CHECKSUMS_FILENAME"
    "$RELEASE_NOTES_FILENAME"
    "$ARCHIVE_METADATA_FILENAME"
)
ARCHIVE_CHECKSUMS_PATH="$ARCHIVE_DIR/$ARCHIVE_CHECKSUMS_FILENAME"
[[ -f "$ARCHIVE_CHECKSUMS_PATH" && ! -L "$ARCHIVE_CHECKSUMS_PATH" ]] \
    || fail "missing archive checksum list"
archive_entry_count="$(find "$ARCHIVE_DIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
archive_regular_file_count="$(find "$ARCHIVE_DIR" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d ' ')"
[[ "$archive_entry_count" -eq 8 && "$archive_regular_file_count" -eq 8 ]] \
    || fail "archive must contain exactly eight regular files and no nested entries"

for filename in "${EXPECTED_FILES[@]}"; do
    safe_filename "$filename" || fail "unsafe archived filename: $filename"
    [[ -f "$ARCHIVE_DIR/$filename" && ! -L "$ARCHIVE_DIR/$filename" ]] \
        || fail "missing regular archived file: $filename"
done

checksum_count=0
while read -r checksum filename trailing; do
    [[ "$checksum" =~ ^[0-9a-f]{64}$ && -n "$filename" && -z "${trailing:-}" ]] \
        || fail "malformed archive checksum entry"
    expected=0
    for expected_file in "${EXPECTED_FILES[@]}"; do
        if [[ "$filename" == "$expected_file" ]]; then
            expected=1
            break
        fi
    done
    [[ "$expected" -eq 1 ]] || fail "unexpected file in archive checksum list: $filename"
    checksum_count=$((checksum_count + 1))
done < "$ARCHIVE_CHECKSUMS_PATH"
[[ "$checksum_count" -eq 7 ]] || fail "archive checksum list must contain seven entries"
for expected_file in "${EXPECTED_FILES[@]}"; do
    [[ "$(awk -v file="$expected_file" '$2 == file { count++ } END { print count + 0 }' "$ARCHIVE_CHECKSUMS_PATH")" -eq 1 ]] \
        || fail "archive checksum missing or duplicated: $expected_file"
done

if ! (
    cd "$ARCHIVE_DIR"
    shasum -a 256 -c "$ARCHIVE_CHECKSUMS_FILENAME"
); then
    fail "one or more archived files do not match their recorded checksum"
fi

RELEASE_MANIFEST_PATH="$ARCHIVE_DIR/$RELEASE_MANIFEST_FILENAME"
manifest_value() {
    plutil -extract "$1" raw "$RELEASE_MANIFEST_PATH"
}
[[ "$(manifest_value version)" == "$APP_VERSION" ]] || fail "archived version metadata drift"
[[ "$(manifest_value buildNumber)" == "$BUILD_NUMBER" ]] || fail "archived build metadata drift"
[[ "$(manifest_value releaseChannel)" == "$RELEASE_CHANNEL" ]] || fail "archived channel metadata drift"
[[ "$(manifest_value git.commit)" == "$GIT_COMMIT" ]] || fail "archived Git metadata drift"
[[ "$(manifest_value binary.machOUUID)" == "$MACHO_UUID" ]] || fail "archived UUID metadata drift"

"$SCRIPT_DIR/verify-macos-release.sh" "${MODE_FLAG[@]}" "$RELEASE_MANIFEST_PATH"
echo "Release archive verification passed: $ARCHIVE_DIR"
