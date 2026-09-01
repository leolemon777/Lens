#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIGURATION="${1:-debug}"
APP_VERSION="${LENS_VERSION:-0.1.0}"
BUILD_VERSION="${LENS_BUILD_NUMBER:-$(date -u +%Y%m%d%H%M%S)}"
BUILD_CHANNEL="${LENS_BUILD_CHANNEL:-development}"
BUILT_AT="${LENS_BUILT_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
GIT_COMMIT="${LENS_GIT_COMMIT:-$(git -C "$PROJECT_DIR" rev-parse --verify HEAD 2>/dev/null || true)}"
GIT_COMMIT="${GIT_COMMIT:-unknown}"
SIGNING_IDENTITY="${LENS_SIGNING_IDENTITY:-}"
CODESIGN_TIMESTAMP_MODE="${LENS_CODESIGN_TIMESTAMP:-required}"
BUILD_DIR="$PROJECT_DIR/Build"
APP_DIR="$BUILD_DIR/Lens.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICON_SOURCE="$PROJECT_DIR/Assets/AppIcon.png"
ENTITLEMENTS_PATH="$PROJECT_DIR/Config/Lens.entitlements"
ICON_TEMP_ROOT=""

if [[ -z "$SIGNING_IDENTITY" ]]; then
    AVAILABLE_SIGNING_IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    for candidate in "Lens Local Code Signing" "PathShot Local Code Signing"; do
        if grep -Fq "\"$candidate\"" <<<"$AVAILABLE_SIGNING_IDENTITIES"; then
            SIGNING_IDENTITY="$candidate"
            break
        fi
    done
    SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
fi

cleanup() {
    if [[ -n "$ICON_TEMP_ROOT" && -d "$ICON_TEMP_ROOT" ]]; then
        rm -rf -- "$ICON_TEMP_ROOT"
    fi
}
trap cleanup EXIT

if [[ ! "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
    echo "Invalid LENS_VERSION: $APP_VERSION" >&2
    exit 64
fi
if [[ ! "$BUILD_VERSION" =~ ^[0-9]+$ ]]; then
    echo "Invalid LENS_BUILD_NUMBER: $BUILD_VERSION" >&2
    exit 64
fi
if [[ ! "$BUILD_CHANNEL" =~ ^(development|beta|release)$ ]]; then
    echo "Invalid LENS_BUILD_CHANNEL: $BUILD_CHANNEL" >&2
    exit 64
fi
if [[ "$CODESIGN_TIMESTAMP_MODE" != "required" && "$CODESIGN_TIMESTAMP_MODE" != "none" ]]; then
    echo "Invalid LENS_CODESIGN_TIMESTAMP: $CODESIGN_TIMESTAMP_MODE (use required or none)" >&2
    exit 64
fi
if [[ "$CODESIGN_TIMESTAMP_MODE" == "none" && "$BUILD_CHANNEL" != "development" ]]; then
    echo "A missing code-signing timestamp is allowed only for development builds." >&2
    exit 64
fi
if [[ ! "$GIT_COMMIT" =~ ^([0-9a-fA-F]{7,64}|unknown)$ ]]; then
    echo "Invalid LENS_GIT_COMMIT: $GIT_COMMIT" >&2
    exit 64
fi

cd "$PROJECT_DIR"
SWIFT_BUILD_ARGUMENTS=(-c "$CONFIGURATION" --product Lens)
if [[ "$CONFIGURATION" == "release" ]]; then
    SWIFT_BUILD_ARGUMENTS+=(-Xswiftc -warnings-as-errors)
fi
swift build "${SWIFT_BUILD_ARGUMENTS[@]}"
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"

EXPECTED_APP_DIR="$PROJECT_DIR/Build/Lens.app"
if [[ "$APP_DIR" != "$EXPECTED_APP_DIR" ]]; then
    echo "Refusing to replace unexpected app path: $APP_DIR" >&2
    exit 64
fi
if [[ -e "$APP_DIR" ]]; then
    rm -rf -- "$APP_DIR"
fi
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN_DIR/Lens" "$MACOS_DIR/Lens"

if [[ ! -f "$ICON_SOURCE" ]]; then
    echo "Missing app icon source: $ICON_SOURCE" >&2
    exit 66
fi
if [[ ! -f "$ENTITLEMENTS_PATH" ]]; then
    echo "Missing app entitlements: $ENTITLEMENTS_PATH" >&2
    exit 66
fi
ICON_TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/Lens-icon.XXXXXX")"
ICONSET_DIR="$ICON_TEMP_ROOT/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"
while read -r filename pixel_size; do
    sips -z "$pixel_size" "$pixel_size" "$ICON_SOURCE" \
        --out "$ICONSET_DIR/$filename" >/dev/null
done <<'ICON_SIZES'
icon_16x16.png 16
icon_16x16@2x.png 32
icon_32x32.png 32
icon_32x32@2x.png 64
icon_128x128.png 128
icon_128x128@2x.png 256
icon_256x256.png 256
icon_256x256@2x.png 512
icon_512x512.png 512
icon_512x512@2x.png 1024
ICON_SIZES
iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"
if [[ ! -s "$RESOURCES_DIR/AppIcon.icns" ]]; then
    echo "App icon generation produced an empty file." >&2
    exit 65
fi

PLIST_PATH="$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Clear dict" "$PLIST_PATH" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleDevelopmentRegion string zh_CN" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Lens" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string Lens" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string app.lens.mac" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFBundleInfoDictionaryVersion string 6.0" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFBundleName string Lens" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $APP_VERSION" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_VERSION" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :LensBuildChannel string $BUILD_CHANNEL" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :LensBuiltAt string $BUILT_AT" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :LensGitCommit string $GIT_COMMIT" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 15.2" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :NSHighResolutionCapable bool true" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :NSMicrophoneUsageDescription string Lens 仅在你主动录屏时使用麦克风。" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :NSCameraUsageDescription string Lens 仅在你主动开启摄像头录制时使用摄像头。" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :NSSpeechRecognitionUsageDescription string Lens 在你开启本地自动整理或主动生成字幕时使用设备端语音识别。" "$PLIST_PATH"

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    codesign \
        --force \
        --deep \
        --entitlements "$ENTITLEMENTS_PATH" \
        --sign - \
        "$APP_DIR"
else
    if [[ "$CODESIGN_TIMESTAMP_MODE" == "required" ]]; then
        CODESIGN_TIMESTAMP_ARGUMENT=(--timestamp)
    else
        CODESIGN_TIMESTAMP_ARGUMENT=(--timestamp=none)
    fi
    codesign \
        --force \
        --deep \
        --entitlements "$ENTITLEMENTS_PATH" \
        --options runtime \
        "${CODESIGN_TIMESTAMP_ARGUMENT[@]}" \
        --sign "$SIGNING_IDENTITY" \
        "$APP_DIR"
fi
echo "Signing identity: $SIGNING_IDENTITY"
echo "Timestamp mode: $CODESIGN_TIMESTAMP_MODE"
echo "Build identity: $APP_VERSION ($BUILD_VERSION) · $BUILD_CHANNEL · ${GIT_COMMIT:0:12} · $BUILT_AT"
echo "$APP_DIR"
