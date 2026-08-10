#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIGURATION="${1:-debug}"
APP_VERSION="${SCREENTRACE_VERSION:-0.1.0}"
BUILD_VERSION="${SCREENTRACE_BUILD_NUMBER:-1}"
SIGNING_IDENTITY="${SCREENTRACE_SIGNING_IDENTITY:--}"
BUILD_DIR="$PROJECT_DIR/Build"
APP_DIR="$BUILD_DIR/ScreenTrace.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICON_SOURCE="$PROJECT_DIR/Assets/AppIcon.png"
ICON_TEMP_ROOT=""

cleanup() {
    if [[ -n "$ICON_TEMP_ROOT" && -d "$ICON_TEMP_ROOT" ]]; then
        rm -rf -- "$ICON_TEMP_ROOT"
    fi
}
trap cleanup EXIT

if [[ ! "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
    echo "Invalid SCREENTRACE_VERSION: $APP_VERSION" >&2
    exit 64
fi
if [[ ! "$BUILD_VERSION" =~ ^[0-9]+$ ]]; then
    echo "Invalid SCREENTRACE_BUILD_NUMBER: $BUILD_VERSION" >&2
    exit 64
fi

cd "$PROJECT_DIR"
swift build -c "$CONFIGURATION" --product ScreenTrace
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"

EXPECTED_APP_DIR="$PROJECT_DIR/Build/ScreenTrace.app"
if [[ "$APP_DIR" != "$EXPECTED_APP_DIR" ]]; then
    echo "Refusing to replace unexpected app path: $APP_DIR" >&2
    exit 64
fi
if [[ -e "$APP_DIR" ]]; then
    rm -rf -- "$APP_DIR"
fi
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN_DIR/ScreenTrace" "$MACOS_DIR/ScreenTrace"

if [[ ! -f "$ICON_SOURCE" ]]; then
    echo "Missing app icon source: $ICON_SOURCE" >&2
    exit 66
fi
ICON_TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ScreenTrace-icon.XXXXXX")"
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
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string 屏迹" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string ScreenTrace" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string app.screentrace.mac" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFBundleInfoDictionaryVersion string 6.0" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFBundleName string ScreenTrace" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $APP_VERSION" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_VERSION" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 15.2" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :NSHighResolutionCapable bool true" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :NSMicrophoneUsageDescription string 屏迹仅在你主动录屏时使用麦克风。" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :NSCameraUsageDescription string 屏迹仅在你主动开启摄像头录制时使用摄像头。" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :NSSpeechRecognitionUsageDescription string 屏迹在你开启本地自动整理或主动生成字幕时使用设备端语音识别。" "$PLIST_PATH"

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    codesign --force --deep --sign - "$APP_DIR"
else
    codesign \
        --force \
        --deep \
        --options runtime \
        --timestamp \
        --sign "$SIGNING_IDENTITY" \
        "$APP_DIR"
fi
echo "$APP_DIR"
