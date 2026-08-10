#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$PROJECT_DIR/Build/ScreenTrace.app"
PLIST_PATH="$APP_DIR/Contents/Info.plist"
SIGNING_IDENTITY="${SCREENTRACE_SIGNING_IDENTITY:--}"
NOTARY_PROFILE="${SCREENTRACE_NOTARY_PROFILE:-}"
APP_NOTARY_REQUEST_ID="not-submitted"
APP_NOTARY_STATUS="not-submitted"
DMG_NOTARY_REQUEST_ID="not-submitted"
DMG_NOTARY_STATUS="not-submitted"

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
RELEASE_MANIFEST_PATH="$RELEASES_DIR/$ARTIFACT_NAME-release.json"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ScreenTrace-release.XXXXXX")"
STAGING_DIR="$TEMP_ROOT/staging"
MOUNT_DIR="$TEMP_ROOT/mount"
TEMP_DMG="$TEMP_ROOT/$ARTIFACT_NAME.dmg"
NOTARY_APP_ARCHIVE="$TEMP_ROOT/$ARTIFACT_NAME.notary.app.zip"
APP_NOTARY_RESULT="$TEMP_ROOT/app-notary-result.json"
DMG_NOTARY_RESULT="$TEMP_ROOT/dmg-notary-result.json"
RELEASE_MANIFEST_PLIST="$TEMP_ROOT/release-manifest.plist"
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
        --wait \
        --output-format json > "$APP_NOTARY_RESULT"
    APP_NOTARY_REQUEST_ID="$(plutil -extract id raw "$APP_NOTARY_RESULT")"
    APP_NOTARY_STATUS="$(plutil -extract status raw "$APP_NOTARY_RESULT")"
    if [[ "$APP_NOTARY_STATUS" != "Accepted" ]]; then
        echo "App notarization was not accepted: $APP_NOTARY_STATUS ($APP_NOTARY_REQUEST_ID)" >&2
        exit 65
    fi
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
        --wait \
        --output-format json > "$DMG_NOTARY_RESULT"
    DMG_NOTARY_REQUEST_ID="$(plutil -extract id raw "$DMG_NOTARY_RESULT")"
    DMG_NOTARY_STATUS="$(plutil -extract status raw "$DMG_NOTARY_RESULT")"
    if [[ "$DMG_NOTARY_STATUS" != "Accepted" ]]; then
        echo "DMG notarization was not accepted: $DMG_NOTARY_STATUS ($DMG_NOTARY_REQUEST_ID)" >&2
        exit 65
    fi
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

APP_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST_PATH")"
MINIMUM_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST_PATH")"
MACHO_UUID="$(xcrun dwarfdump --uuid "$APP_DIR/Contents/MacOS/ScreenTrace" | awk 'NR == 1 { print $2 }')"
GIT_COMMIT="$(git -C "$PROJECT_DIR" rev-parse HEAD)"
if [[ -n "$(git -C "$PROJECT_DIR" status --porcelain --untracked-files=no)" ]]; then
    GIT_WORKTREE_STATE="dirty"
else
    GIT_WORKTREE_STATE="clean"
fi
SIGNATURE_DETAILS="$(codesign -dv --verbose=4 "$APP_DIR" 2>&1)"
TEAM_IDENTIFIER="$(awk -F= '/^TeamIdentifier=/{print $2; exit}' <<< "$SIGNATURE_DETAILS")"
SIGNING_AUTHORITY="$(awk -F= '/^Authority=/{print substr($0, index($0, "=") + 1); exit}' <<< "$SIGNATURE_DETAILS")"
if [[ -z "$TEAM_IDENTIFIER" || "$TEAM_IDENTIFIER" == "not set" ]]; then
    TEAM_IDENTIFIER="not-set"
fi
if grep -q '^Signature=adhoc$' <<< "$SIGNATURE_DETAILS"; then
    SIGNATURE_KIND="ad-hoc"
    RECORDED_SIGNING_IDENTITY="ad-hoc"
elif [[ "$SIGNING_AUTHORITY" == "Developer ID Application:"* \
    && "$TEAM_IDENTIFIER" != "not-set" ]]; then
    SIGNATURE_KIND="developer-id"
    RECORDED_SIGNING_IDENTITY="$SIGNING_AUTHORITY"
else
    SIGNATURE_KIND="local"
    RECORDED_SIGNING_IDENTITY="${SIGNING_AUTHORITY:-$SIGNING_IDENTITY}"
fi

DMG_SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
APP_ARCHIVE_SHA256="$(shasum -a 256 "$APP_ARCHIVE" | awk '{print $1}')"
DSYM_ARCHIVE_SHA256="$(shasum -a 256 "$RELEASE_SYMBOLS" | awk '{print $1}')"
DMG_SIZE="$(stat -f '%z' "$DMG_PATH")"
APP_ARCHIVE_SIZE="$(stat -f '%z' "$APP_ARCHIVE")"
DSYM_ARCHIVE_SIZE="$(stat -f '%z' "$RELEASE_SYMBOLS")"

plutil -create xml1 "$RELEASE_MANIFEST_PLIST"
plutil -insert schemaVersion -integer 1 "$RELEASE_MANIFEST_PLIST"
plutil -insert product -string "ScreenTrace" "$RELEASE_MANIFEST_PLIST"
plutil -insert bundleIdentifier -string "$APP_BUNDLE_ID" "$RELEASE_MANIFEST_PLIST"
plutil -insert version -string "$APP_VERSION" "$RELEASE_MANIFEST_PLIST"
plutil -insert buildNumber -string "$BUILD_VERSION" "$RELEASE_MANIFEST_PLIST"
plutil -insert minimumMacOS -string "$MINIMUM_MACOS" "$RELEASE_MANIFEST_PLIST"
plutil -insert git -dictionary "$RELEASE_MANIFEST_PLIST"
plutil -insert git.commit -string "$GIT_COMMIT" "$RELEASE_MANIFEST_PLIST"
plutil -insert git.worktree -string "$GIT_WORKTREE_STATE" "$RELEASE_MANIFEST_PLIST"
plutil -insert binary -dictionary "$RELEASE_MANIFEST_PLIST"
plutil -insert binary.machOUUID -string "$MACHO_UUID" "$RELEASE_MANIFEST_PLIST"
plutil -insert signing -dictionary "$RELEASE_MANIFEST_PLIST"
plutil -insert signing.kind -string "$SIGNATURE_KIND" "$RELEASE_MANIFEST_PLIST"
plutil -insert signing.identity -string "$RECORDED_SIGNING_IDENTITY" "$RELEASE_MANIFEST_PLIST"
plutil -insert signing.teamIdentifier -string "$TEAM_IDENTIFIER" "$RELEASE_MANIFEST_PLIST"
plutil -insert notarization -dictionary "$RELEASE_MANIFEST_PLIST"
plutil -insert notarization.app -dictionary "$RELEASE_MANIFEST_PLIST"
plutil -insert notarization.app.requestID -string "$APP_NOTARY_REQUEST_ID" "$RELEASE_MANIFEST_PLIST"
plutil -insert notarization.app.status -string "$APP_NOTARY_STATUS" "$RELEASE_MANIFEST_PLIST"
plutil -insert notarization.dmg -dictionary "$RELEASE_MANIFEST_PLIST"
plutil -insert notarization.dmg.requestID -string "$DMG_NOTARY_REQUEST_ID" "$RELEASE_MANIFEST_PLIST"
plutil -insert notarization.dmg.status -string "$DMG_NOTARY_STATUS" "$RELEASE_MANIFEST_PLIST"
plutil -insert artifacts -array "$RELEASE_MANIFEST_PLIST"
plutil -insert artifacts.0 -dictionary "$RELEASE_MANIFEST_PLIST"
plutil -insert artifacts.0.kind -string "dmg" "$RELEASE_MANIFEST_PLIST"
plutil -insert artifacts.0.file -string "$(basename "$DMG_PATH")" "$RELEASE_MANIFEST_PLIST"
plutil -insert artifacts.0.bytes -integer "$DMG_SIZE" "$RELEASE_MANIFEST_PLIST"
plutil -insert artifacts.0.sha256 -string "$DMG_SHA256" "$RELEASE_MANIFEST_PLIST"
plutil -insert artifacts.1 -dictionary "$RELEASE_MANIFEST_PLIST"
plutil -insert artifacts.1.kind -string "app-zip" "$RELEASE_MANIFEST_PLIST"
plutil -insert artifacts.1.file -string "$(basename "$APP_ARCHIVE")" "$RELEASE_MANIFEST_PLIST"
plutil -insert artifacts.1.bytes -integer "$APP_ARCHIVE_SIZE" "$RELEASE_MANIFEST_PLIST"
plutil -insert artifacts.1.sha256 -string "$APP_ARCHIVE_SHA256" "$RELEASE_MANIFEST_PLIST"
plutil -insert artifacts.2 -dictionary "$RELEASE_MANIFEST_PLIST"
plutil -insert artifacts.2.kind -string "dsym-zip" "$RELEASE_MANIFEST_PLIST"
plutil -insert artifacts.2.file -string "$(basename "$RELEASE_SYMBOLS")" "$RELEASE_MANIFEST_PLIST"
plutil -insert artifacts.2.bytes -integer "$DSYM_ARCHIVE_SIZE" "$RELEASE_MANIFEST_PLIST"
plutil -insert artifacts.2.sha256 -string "$DSYM_ARCHIVE_SHA256" "$RELEASE_MANIFEST_PLIST"
plutil -convert json -r -o "$RELEASE_MANIFEST_PATH" "$RELEASE_MANIFEST_PLIST"

verify_manifest_value() {
    local key_path="$1"
    local expected="$2"
    local actual
    actual="$(plutil -extract "$key_path" raw "$RELEASE_MANIFEST_PATH")"
    if [[ "$actual" != "$expected" ]]; then
        echo "Release manifest mismatch for $key_path: expected=$expected actual=$actual" >&2
        exit 65
    fi
}

verify_manifest_value "schemaVersion" "1"
verify_manifest_value "bundleIdentifier" "$APP_BUNDLE_ID"
verify_manifest_value "version" "$APP_VERSION"
verify_manifest_value "buildNumber" "$BUILD_VERSION"
verify_manifest_value "binary.machOUUID" "$MACHO_UUID"
verify_manifest_value "artifacts.0.sha256" "$DMG_SHA256"
verify_manifest_value "artifacts.1.sha256" "$APP_ARCHIVE_SHA256"
verify_manifest_value "artifacts.2.sha256" "$DSYM_ARCHIVE_SHA256"

(
    cd "$RELEASES_DIR"
    shasum -a 256 \
        "$(basename "$DMG_PATH")" \
        "$(basename "$APP_ARCHIVE")" \
        "$(basename "$RELEASE_SYMBOLS")" \
        "$(basename "$RELEASE_MANIFEST_PATH")"
) > "$CHECKSUMS_PATH"

echo "DMG: $DMG_PATH"
echo "App archive: $APP_ARCHIVE"
echo "dSYM archive: $RELEASE_SYMBOLS"
echo "Release manifest: $RELEASE_MANIFEST_PATH"
echo "Checksums: $CHECKSUMS_PATH"
cat "$CHECKSUMS_PATH"
