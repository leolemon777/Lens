#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$PROJECT_DIR/Build/Lens.app"
PLIST_PATH="$APP_DIR/Contents/Info.plist"
BINARY_PATH="$APP_DIR/Contents/MacOS/Lens"

"$SCRIPT_DIR/build-app.sh" release
plutil -lint "$PLIST_PATH"
codesign --verify --deep --strict "$APP_DIR"

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST_PATH")"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST_PATH")"
ARTIFACT_NAME="Lens-$APP_VERSION-$BUILD_VERSION"
SYMBOLS_DIR="$PROJECT_DIR/Build/Symbols"
DSYM_PATH="$SYMBOLS_DIR/$ARTIFACT_NAME.dSYM"
ARCHIVE_PATH="$SYMBOLS_DIR/$ARTIFACT_NAME.dSYM.zip"

mkdir -p "$SYMBOLS_DIR"
if [[ -e "$DSYM_PATH" ]]; then
    rm -rf "$DSYM_PATH"
fi
if [[ -e "$ARCHIVE_PATH" ]]; then
    rm -f "$ARCHIVE_PATH"
fi

xcrun dsymutil "$BINARY_PATH" -o "$DSYM_PATH"

BINARY_UUID="$(xcrun dwarfdump --uuid "$BINARY_PATH" | awk 'NR == 1 { print $2 }')"
DSYM_UUID="$(xcrun dwarfdump --uuid "$DSYM_PATH" | awk 'NR == 1 { print $2 }')"
if [[ -z "$BINARY_UUID" || "$BINARY_UUID" != "$DSYM_UUID" ]]; then
    echo "dSYM UUID mismatch: binary=$BINARY_UUID symbols=$DSYM_UUID" >&2
    exit 1
fi

ditto -c -k --keepParent "$DSYM_PATH" "$ARCHIVE_PATH"
unzip -tq "$ARCHIVE_PATH"

echo "App: $APP_DIR"
echo "dSYM: $DSYM_PATH"
echo "Archive: $ARCHIVE_PATH"
echo "Mach-O UUID: $BINARY_UUID"
shasum -a 256 "$ARCHIVE_PATH"
