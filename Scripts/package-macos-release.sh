#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$PROJECT_DIR/Build/ScreenTrace.app"
PLIST_PATH="$APP_DIR/Contents/Info.plist"
SIGNING_IDENTITY="${SCREENTRACE_SIGNING_IDENTITY:--}"
NOTARY_PROFILE="${SCREENTRACE_NOTARY_PROFILE:-}"

if [[ -n "$NOTARY_PROFILE" && "$SIGNING_IDENTITY" == "-" ]]; then
    echo "SCREENTRACE_NOTARY_PROFILE requires a Developer ID signing identity." >&2
    exit 64
fi

"$SCRIPT_DIR/build-release-artifacts.sh"

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST_PATH")"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST_PATH")"
ARTIFACT_NAME="ScreenTrace-$APP_VERSION-$BUILD_VERSION"
RELEASES_DIR="$PROJECT_DIR/Build/Releases"
SYMBOL_ARCHIVE="$PROJECT_DIR/Build/Symbols/$ARTIFACT_NAME.dSYM.zip"
APP_ARCHIVE="$RELEASES_DIR/$ARTIFACT_NAME.app.zip"
DMG_PATH="$RELEASES_DIR/$ARTIFACT_NAME.dmg"
RELEASE_SYMBOLS="$RELEASES_DIR/$ARTIFACT_NAME.dSYM.zip"
CHECKSUMS_PATH="$RELEASES_DIR/$ARTIFACT_NAME-SHA256SUMS.txt"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ScreenTrace-release.XXXXXX")"
STAGING_DIR="$TEMP_ROOT/staging"
MOUNT_DIR="$TEMP_ROOT/mount"
TEMP_DMG="$TEMP_ROOT/$ARTIFACT_NAME.dmg"
NOTARY_APP_ARCHIVE="$TEMP_ROOT/$ARTIFACT_NAME.notary.app.zip"
MOUNTED=0

cleanup() {
    if [[ "$MOUNTED" -eq 1 ]]; then
        hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
    fi
    rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$RELEASES_DIR" "$STAGING_DIR" "$MOUNT_DIR"

if [[ -n "$NOTARY_PROFILE" ]]; then
    ditto -c -k --keepParent "$APP_DIR" "$NOTARY_APP_ARCHIVE"
    unzip -tq "$NOTARY_APP_ARCHIVE"
    xcrun notarytool submit \
        "$NOTARY_APP_ARCHIVE" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait
    xcrun stapler staple "$APP_DIR"
    xcrun stapler validate "$APP_DIR"
    codesign --verify --deep --strict --verbose=2 "$APP_DIR"
    spctl --assess --type execute --verbose=4 "$APP_DIR"
else
    echo "Notarization skipped: SCREENTRACE_NOTARY_PROFILE is not set." >&2
fi

ditto "$APP_DIR" "$STAGING_DIR/ScreenTrace.app"
ln -s /Applications "$STAGING_DIR/Applications"

ditto -c -k --keepParent "$APP_DIR" "$APP_ARCHIVE"
unzip -tq "$APP_ARCHIVE"
ditto "$SYMBOL_ARCHIVE" "$RELEASE_SYMBOLS"

hdiutil create \
    -volname "ScreenTrace" \
    -srcfolder "$STAGING_DIR" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    "$TEMP_DMG"
hdiutil verify "$TEMP_DMG"

if [[ "$SIGNING_IDENTITY" != "-" ]]; then
    codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$TEMP_DMG"
    codesign --verify --verbose=2 "$TEMP_DMG"
fi

if [[ -n "$NOTARY_PROFILE" ]]; then
    xcrun notarytool submit \
        "$TEMP_DMG" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait
    xcrun stapler staple "$TEMP_DMG"
    xcrun stapler validate "$TEMP_DMG"
    spctl \
        --assess \
        --type open \
        --context context:primary-signature \
        --verbose=4 \
        "$TEMP_DMG"
fi

ditto "$TEMP_DMG" "$DMG_PATH"
hdiutil verify "$DMG_PATH"
hdiutil attach \
    -readonly \
    -nobrowse \
    -mountpoint "$MOUNT_DIR" \
    "$DMG_PATH" >/dev/null
MOUNTED=1

codesign --verify --deep --strict "$MOUNT_DIR/ScreenTrace.app"
plutil -lint "$MOUNT_DIR/ScreenTrace.app/Contents/Info.plist"
if [[ -n "$NOTARY_PROFILE" ]]; then
    xcrun stapler validate "$MOUNT_DIR/ScreenTrace.app"
    spctl --assess --type execute --verbose=4 "$MOUNT_DIR/ScreenTrace.app"
fi
if [[ ! -L "$MOUNT_DIR/Applications" || "$(readlink "$MOUNT_DIR/Applications")" != "/Applications" ]]; then
    echo "DMG Applications link is missing or invalid." >&2
    exit 65
fi

hdiutil detach "$MOUNT_DIR" >/dev/null
MOUNTED=0

(
    cd "$RELEASES_DIR"
    shasum -a 256 \
        "$(basename "$DMG_PATH")" \
        "$(basename "$APP_ARCHIVE")" \
        "$(basename "$RELEASE_SYMBOLS")"
) > "$CHECKSUMS_PATH"

echo "DMG: $DMG_PATH"
echo "App archive: $APP_ARCHIVE"
echo "dSYM archive: $RELEASE_SYMBOLS"
echo "Checksums: $CHECKSUMS_PATH"
cat "$CHECKSUMS_PATH"
