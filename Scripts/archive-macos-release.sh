#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODE_FLAG=()

if [[ "${1:-}" == "--development" ]]; then
    MODE_FLAG=(--development)
    shift
fi
if [[ $# -ne 2 ]]; then
    echo "Usage: $0 [--development] <release.json> <archive-root>" >&2
    exit 64
fi

[[ -f "$1" && ! -L "$1" ]] \
    || { echo "Release manifest must be a regular file: $1" >&2; exit 66; }
MANIFEST_PATH="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
MANIFEST_DIR="$(dirname "$MANIFEST_PATH")"
mkdir -p "$2"
[[ -d "$2" && ! -L "$2" ]] \
    || { echo "Archive root must be a regular directory: $2" >&2; exit 66; }
ARCHIVE_ROOT="$(cd "$2" && pwd)"

"$SCRIPT_DIR/verify-macos-release.sh" "${MODE_FLAG[@]}" "$MANIFEST_PATH"

manifest_value() {
    plutil -extract "$1" raw "$MANIFEST_PATH"
}

APP_VERSION="$(manifest_value version)"
BUILD_NUMBER="$(manifest_value buildNumber)"
RELEASE_CHANNEL="$(manifest_value releaseChannel)"
GIT_COMMIT="$(manifest_value git.commit)"
MACHO_UUID="$(manifest_value binary.machOUUID)"
ARTIFACT_NAME="ScreenTrace-$APP_VERSION-$BUILD_NUMBER"
RELEASE_MANIFEST_FILENAME="$ARTIFACT_NAME-release.json"
RELEASE_CHECKSUMS_FILENAME="$ARTIFACT_NAME-SHA256SUMS.txt"
RELEASE_NOTES_FILENAME="$ARTIFACT_NAME-RELEASE_NOTES.md"
ARCHIVE_METADATA_FILENAME="$ARTIFACT_NAME-archive.json"
ARCHIVE_CHECKSUMS_FILENAME="$ARTIFACT_NAME-ARCHIVE_SHA256SUMS.txt"
TARGET_DIR="$ARCHIVE_ROOT/$ARTIFACT_NAME-${GIT_COMMIT:0:12}"
TEMP_DIR="$(mktemp -d "$ARCHIVE_ROOT/.ScreenTrace-archive.XXXXXX")"
METADATA_PLIST="$TEMP_DIR/.archive-metadata.plist"

cleanup() {
    if [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]]; then
        rm -rf -- "$TEMP_DIR"
    fi
}
trap cleanup EXIT

[[ "$GIT_COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "Invalid Git commit in release manifest." >&2; exit 65; }
[[ ! -e "$TARGET_DIR" ]] \
    || { echo "Refusing to overwrite existing release archive: $TARGET_DIR" >&2; exit 65; }

SOURCE_FILES=(
    "$ARTIFACT_NAME.dmg"
    "$ARTIFACT_NAME.app.zip"
    "$ARTIFACT_NAME.dSYM.zip"
    "$RELEASE_MANIFEST_FILENAME"
    "$RELEASE_CHECKSUMS_FILENAME"
    "$RELEASE_NOTES_FILENAME"
)
for filename in "${SOURCE_FILES[@]}"; do
    [[ -f "$MANIFEST_DIR/$filename" && ! -L "$MANIFEST_DIR/$filename" ]] \
        || { echo "Missing regular release file: $filename" >&2; exit 65; }
    ditto "$MANIFEST_DIR/$filename" "$TEMP_DIR/$filename"
done

plutil -create xml1 "$METADATA_PLIST"
plutil -insert schemaVersion -integer 1 "$METADATA_PLIST"
plutil -insert product -string "ScreenTrace" "$METADATA_PLIST"
plutil -insert version -string "$APP_VERSION" "$METADATA_PLIST"
plutil -insert buildNumber -string "$BUILD_NUMBER" "$METADATA_PLIST"
plutil -insert releaseChannel -string "$RELEASE_CHANNEL" "$METADATA_PLIST"
plutil -insert gitCommit -string "$GIT_COMMIT" "$METADATA_PLIST"
plutil -insert machOUUID -string "$MACHO_UUID" "$METADATA_PLIST"
plutil -insert releaseManifest -string "$RELEASE_MANIFEST_FILENAME" "$METADATA_PLIST"
plutil -convert json -r -o "$TEMP_DIR/$ARCHIVE_METADATA_FILENAME" "$METADATA_PLIST"
rm -f "$METADATA_PLIST"

(
    cd "$TEMP_DIR"
    shasum -a 256 \
        "${SOURCE_FILES[@]}" \
        "$ARCHIVE_METADATA_FILENAME"
) > "$TEMP_DIR/$ARCHIVE_CHECKSUMS_FILENAME"

"$SCRIPT_DIR/verify-macos-release-archive.sh" "${MODE_FLAG[@]}" "$TEMP_DIR"
mv "$TEMP_DIR" "$TARGET_DIR"
TEMP_DIR=""
trap - EXIT
echo "Release archive created: $TARGET_DIR"
