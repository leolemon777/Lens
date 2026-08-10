#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MODE="public"

usage() {
    echo "Usage: $0 [--development] <release.json>" >&2
    exit 64
}

if [[ "${1:-}" == "--development" ]]; then
    MODE="development"
    shift
fi
[[ $# -eq 1 ]] || usage
[[ -f "$1" ]] || { echo "Release manifest does not exist: $1" >&2; exit 66; }

MANIFEST_DIR="$(cd "$(dirname "$1")" && pwd)"
MANIFEST_PATH="$MANIFEST_DIR/$(basename "$1")"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ScreenTrace-verify-release.XXXXXX")"
APP_UNPACK_DIR="$TEMP_ROOT/app"
DSYM_UNPACK_DIR="$TEMP_ROOT/dsym"
MOUNT_DIR="$TEMP_ROOT/mount"
MOUNTED=0

cleanup() {
    if [[ "$MOUNTED" -eq 1 ]]; then
        hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
    fi
    rm -rf -- "$TEMP_ROOT"
}
trap cleanup EXIT

fail() {
    echo "release verification failed: $1" >&2
    exit 65
}

PUBLIC_FAILURES=()

public_fail() {
    PUBLIC_FAILURES+=("$1")
}

manifest_value() {
    plutil -extract "$1" raw "$MANIFEST_PATH"
}

expect_value() {
    local label="$1"
    local actual="$2"
    local expected="$3"
    [[ "$actual" == "$expected" ]] || fail "$label expected=$expected actual=$actual"
}

safe_artifact_name() {
    local filename="$1"
    [[ -n "$filename" && "$filename" != */* && "$filename" != "." && "$filename" != ".." ]]
}

verify_recorded_artifact() {
    local index="$1"
    local expected_kind="$2"
    local expected_filename="$3"
    local kind filename expected_bytes expected_sha path actual_bytes actual_sha
    kind="$(manifest_value "artifacts.$index.kind")"
    filename="$(manifest_value "artifacts.$index.file")"
    expected_bytes="$(manifest_value "artifacts.$index.bytes")"
    expected_sha="$(manifest_value "artifacts.$index.sha256")"
    expect_value "artifact $index kind" "$kind" "$expected_kind"
    expect_value "artifact $index filename" "$filename" "$expected_filename"
    safe_artifact_name "$filename" || fail "unsafe artifact filename: $filename"
    path="$MANIFEST_DIR/$filename"
    [[ -f "$path" ]] || fail "missing artifact: $path"
    actual_bytes="$(stat -f '%z' "$path")"
    actual_sha="$(shasum -a 256 "$path" | awk '{print $1}')"
    expect_value "$filename byte count" "$actual_bytes" "$expected_bytes"
    expect_value "$filename SHA-256" "$actual_sha" "$expected_sha"
}

verify_app_bundle() {
    local app_path="$1"
    local plist="$app_path/Contents/Info.plist"
    local executable="$app_path/Contents/MacOS/ScreenTrace"
    local icon="$app_path/Contents/Resources/AppIcon.icns"
    local uuid
    [[ -f "$plist" ]] || fail "missing Info.plist in $app_path"
    [[ -x "$executable" ]] || fail "missing executable in $app_path"
    [[ -s "$icon" ]] || fail "missing AppIcon.icns in $app_path"
    plutil -lint "$plist" >/dev/null
    expect_value "bundle identifier" \
        "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" \
        "$BUNDLE_IDENTIFIER"
    expect_value "bundle version" \
        "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" \
        "$APP_VERSION"
    expect_value "bundle build number" \
        "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" \
        "$BUILD_NUMBER"
    expect_value "minimum macOS" \
        "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist")" \
        "$MINIMUM_MACOS"
    expect_value "bundle icon key" \
        "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$plist")" \
        "AppIcon"
    uuid="$(xcrun dwarfdump --uuid "$executable" | awk 'NR == 1 { print $2 }')"
    expect_value "App Mach-O UUID" "$uuid" "$MACHO_UUID"
    codesign --verify --deep --strict --verbose=2 "$app_path"
}

expect_value "release manifest schema" "$(manifest_value schemaVersion)" "1"
expect_value "release product" "$(manifest_value product)" "ScreenTrace"
BUNDLE_IDENTIFIER="$(manifest_value bundleIdentifier)"
APP_VERSION="$(manifest_value version)"
BUILD_NUMBER="$(manifest_value buildNumber)"
RELEASE_CHANNEL="$(manifest_value releaseChannel)"
MINIMUM_MACOS="$(manifest_value minimumMacOS)"
MACHO_UUID="$(manifest_value binary.machOUUID)"
GIT_COMMIT="$(manifest_value git.commit)"
GIT_WORKTREE="$(manifest_value git.worktree)"
SIGNING_KIND="$(manifest_value signing.kind)"
TEAM_IDENTIFIER="$(manifest_value signing.teamIdentifier)"
APP_NOTARY_ID="$(manifest_value notarization.app.requestID)"
APP_NOTARY_STATUS="$(manifest_value notarization.app.status)"
DMG_NOTARY_ID="$(manifest_value notarization.dmg.requestID)"
DMG_NOTARY_STATUS="$(manifest_value notarization.dmg.status)"

expect_value "bundle identifier" "$BUNDLE_IDENTIFIER" "app.screentrace.mac"
[[ "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || fail "invalid version: $APP_VERSION"
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || fail "invalid build number: $BUILD_NUMBER"
case "$RELEASE_CHANNEL" in
    alpha|beta|stable) ;;
    *) fail "invalid release channel: $RELEASE_CHANNEL" ;;
esac
[[ -n "$MINIMUM_MACOS" && -n "$MACHO_UUID" ]] || fail "missing platform or UUID metadata"
expect_value "release worktree state" "$GIT_WORKTREE" "clean"
expect_value "release Git commit" "$GIT_COMMIT" "$(git -C "$PROJECT_DIR" rev-parse HEAD)"
[[ -z "$(git -C "$PROJECT_DIR" status --porcelain)" ]] \
    || fail "current Git worktree is not clean"

ARTIFACT_NAME="ScreenTrace-$APP_VERSION-$BUILD_NUMBER"
expect_value "release manifest filename" "$(basename "$MANIFEST_PATH")" \
    "$ARTIFACT_NAME-release.json"
DMG_FILENAME="$ARTIFACT_NAME.dmg"
APP_ARCHIVE_FILENAME="$ARTIFACT_NAME.app.zip"
DSYM_ARCHIVE_FILENAME="$ARTIFACT_NAME.dSYM.zip"
CHECKSUMS_FILENAME="$ARTIFACT_NAME-SHA256SUMS.txt"
RELEASE_NOTES_FILENAME="$ARTIFACT_NAME-RELEASE_NOTES.md"
DMG_PATH="$MANIFEST_DIR/$DMG_FILENAME"
APP_ARCHIVE_PATH="$MANIFEST_DIR/$APP_ARCHIVE_FILENAME"
DSYM_ARCHIVE_PATH="$MANIFEST_DIR/$DSYM_ARCHIVE_FILENAME"
CHECKSUMS_PATH="$MANIFEST_DIR/$CHECKSUMS_FILENAME"
RELEASE_NOTES_PATH="$MANIFEST_DIR/$RELEASE_NOTES_FILENAME"

verify_recorded_artifact 0 "dmg" "$DMG_FILENAME"
verify_recorded_artifact 1 "app-zip" "$APP_ARCHIVE_FILENAME"
verify_recorded_artifact 2 "dsym-zip" "$DSYM_ARCHIVE_FILENAME"
[[ -f "$CHECKSUMS_PATH" ]] || fail "missing checksums file: $CHECKSUMS_PATH"
[[ -f "$RELEASE_NOTES_PATH" ]] || fail "missing release notes: $RELEASE_NOTES_PATH"

checksum_count=0
dmg_checksum_count=0
app_checksum_count=0
dsym_checksum_count=0
manifest_checksum_count=0
release_notes_checksum_count=0
while read -r checksum filename trailing; do
    [[ "$checksum" =~ ^[0-9a-f]{64}$ && -n "$filename" && -z "${trailing:-}" ]] \
        || fail "malformed checksum line in $CHECKSUMS_FILENAME"
    case "$filename" in
        "$DMG_FILENAME")
            dmg_checksum_count=$((dmg_checksum_count + 1))
            ;;
        "$APP_ARCHIVE_FILENAME")
            app_checksum_count=$((app_checksum_count + 1))
            ;;
        "$DSYM_ARCHIVE_FILENAME")
            dsym_checksum_count=$((dsym_checksum_count + 1))
            ;;
        "$(basename "$MANIFEST_PATH")")
            manifest_checksum_count=$((manifest_checksum_count + 1))
            ;;
        "$RELEASE_NOTES_FILENAME")
            release_notes_checksum_count=$((release_notes_checksum_count + 1))
            ;;
        *)
            fail "unexpected file in checksum list: $filename"
            ;;
    esac
    checksum_count=$((checksum_count + 1))
done < "$CHECKSUMS_PATH"
expect_value "checksum entry count" "$checksum_count" "5"
expect_value "DMG checksum entry count" "$dmg_checksum_count" "1"
expect_value "App checksum entry count" "$app_checksum_count" "1"
expect_value "dSYM checksum entry count" "$dsym_checksum_count" "1"
expect_value "manifest checksum entry count" "$manifest_checksum_count" "1"
expect_value "release notes checksum entry count" "$release_notes_checksum_count" "1"
if ! (
    cd "$MANIFEST_DIR"
    shasum -a 256 -c "$CHECKSUMS_FILENAME"
); then
    fail "one or more release artifact checksums do not match"
fi

grep -Fqx -- "- 发布级别: $RELEASE_CHANNEL" "$RELEASE_NOTES_PATH" \
    || fail "release notes channel does not match manifest"
grep -Fqx -- "- Bundle ID: $BUNDLE_IDENTIFIER" "$RELEASE_NOTES_PATH" \
    || fail "release notes Bundle ID does not match manifest"
grep -Fqx -- "- 最低系统: macOS $MINIMUM_MACOS 或更高" "$RELEASE_NOTES_PATH" \
    || fail "release notes minimum macOS does not match manifest"
grep -Fqx -- "- Git commit: $GIT_COMMIT" "$RELEASE_NOTES_PATH" \
    || fail "release notes Git commit does not match manifest"
grep -Fqx -- "- Mach-O UUID: $MACHO_UUID" "$RELEASE_NOTES_PATH" \
    || fail "release notes Mach-O UUID does not match manifest"
for required_heading in "## 权限与数据" "## 已知限制" "## SHA-256"; do
    grep -Fqx -- "$required_heading" "$RELEASE_NOTES_PATH" \
        || fail "release notes missing required section: $required_heading"
done
while read -r checksum filename trailing; do
    if [[ "$filename" != "$RELEASE_NOTES_FILENAME" ]]; then
        grep -Fqx -- "$checksum  $filename" "$RELEASE_NOTES_PATH" \
            || fail "release notes missing checksum for $filename"
    fi
done < "$CHECKSUMS_PATH"

unzip -tq "$APP_ARCHIVE_PATH"
unzip -tq "$DSYM_ARCHIVE_PATH"
mkdir -p "$APP_UNPACK_DIR" "$DSYM_UNPACK_DIR" "$MOUNT_DIR"
ditto -x -k "$APP_ARCHIVE_PATH" "$APP_UNPACK_DIR"
ditto -x -k "$DSYM_ARCHIVE_PATH" "$DSYM_UNPACK_DIR"
ARCHIVED_APP="$APP_UNPACK_DIR/ScreenTrace.app"
ARCHIVED_DSYM="$DSYM_UNPACK_DIR/$ARTIFACT_NAME.dSYM"
[[ -d "$ARCHIVED_APP" ]] || fail "App archive has an unexpected root layout"
[[ -d "$ARCHIVED_DSYM" ]] || fail "dSYM archive has an unexpected root layout"
verify_app_bundle "$ARCHIVED_APP"
DSYM_UUID="$(xcrun dwarfdump --uuid "$ARCHIVED_DSYM" | awk 'NR == 1 { print $2 }')"
expect_value "dSYM UUID" "$DSYM_UUID" "$MACHO_UUID"

hdiutil verify "$DMG_PATH"
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_DIR" "$DMG_PATH" >/dev/null
MOUNTED=1
MOUNTED_APP="$MOUNT_DIR/ScreenTrace.app"
verify_app_bundle "$MOUNTED_APP"
if [[ ! -L "$MOUNT_DIR/Applications" || "$(readlink "$MOUNT_DIR/Applications")" != "/Applications" ]]; then
    fail "DMG Applications link is missing or invalid"
fi

if [[ "$MODE" == "public" ]]; then
    [[ -f "$PROJECT_DIR/LICENSE" ]] \
        || public_fail "selected root LICENSE is missing"
    [[ "$SIGNING_KIND" == "developer-id" ]] \
        || public_fail "signature kind expected=developer-id actual=$SIGNING_KIND"
    [[ -n "$TEAM_IDENTIFIER" && "$TEAM_IDENTIFIER" != "not-set" ]] \
        || public_fail "signing Team ID is missing"
    [[ "$APP_NOTARY_STATUS" == "Accepted" ]] \
        || public_fail "App notarization status expected=Accepted actual=$APP_NOTARY_STATUS"
    [[ "$DMG_NOTARY_STATUS" == "Accepted" ]] \
        || public_fail "DMG notarization status expected=Accepted actual=$DMG_NOTARY_STATUS"
    [[ -n "$APP_NOTARY_ID" && "$APP_NOTARY_ID" != "not-submitted" ]] \
        || public_fail "App notarization request ID is missing"
    [[ -n "$DMG_NOTARY_ID" && "$DMG_NOTARY_ID" != "not-submitted" ]] \
        || public_fail "DMG notarization request ID is missing"
    SIGNATURE_DETAILS="$(codesign -dv --verbose=4 "$ARCHIVED_APP" 2>&1)"
    ACTUAL_TEAM_IDENTIFIER="$(awk -F= '/^TeamIdentifier=/{print $2; exit}' <<< "$SIGNATURE_DETAILS")"
    ACTUAL_SIGNING_AUTHORITY="$(awk -F= '/^Authority=/{print substr($0, index($0, "=") + 1); exit}' <<< "$SIGNATURE_DETAILS")"
    [[ "$ACTUAL_SIGNING_AUTHORITY" == "Developer ID Application:"* ]] \
        || public_fail "App signing Authority is not Developer ID Application: ${ACTUAL_SIGNING_AUTHORITY:-missing}"
    if [[ -n "$TEAM_IDENTIFIER" && "$TEAM_IDENTIFIER" != "not-set" \
        && "$ACTUAL_TEAM_IDENTIFIER" != "$TEAM_IDENTIFIER" ]]; then
        public_fail "signed App Team ID expected=$TEAM_IDENTIFIER actual=${ACTUAL_TEAM_IDENTIFIER:-missing}"
    fi
    if ! bash "$SCRIPT_DIR/audit-public-source.sh" >/dev/null; then
        public_fail "public-source audit failed"
    fi
    if ! xcrun stapler validate "$ARCHIVED_APP" >/dev/null 2>&1; then
        public_fail "App staple validation failed"
    fi
    if ! xcrun stapler validate "$DMG_PATH" >/dev/null 2>&1; then
        public_fail "DMG staple validation failed"
    fi
    if ! spctl --assess --type execute --verbose=4 "$ARCHIVED_APP" >/dev/null 2>&1; then
        public_fail "App Gatekeeper assessment failed"
    fi
    if ! codesign --verify --verbose=2 "$DMG_PATH" >/dev/null 2>&1; then
        public_fail "DMG signature verification failed"
    fi
    if ! spctl --assess --type open --context context:primary-signature \
        --verbose=4 "$DMG_PATH" >/dev/null 2>&1; then
        public_fail "DMG Gatekeeper assessment failed"
    fi
    if [[ "${#PUBLIC_FAILURES[@]}" -gt 0 ]]; then
        echo "release verification failed: public qualification has ${#PUBLIC_FAILURES[@]} blocker(s):" >&2
        printf '  - %s\n' "${PUBLIC_FAILURES[@]}" >&2
        exit 65
    fi
    echo "Public macOS release verification passed: $ARTIFACT_NAME"
else
    echo "Development release structure passed: $ARTIFACT_NAME"
    echo "Public qualification not checked (signing=$SIGNING_KIND, app-notary=$APP_NOTARY_STATUS, dmg-notary=$DMG_NOTARY_STATUS)."
fi
