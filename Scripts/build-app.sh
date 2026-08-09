#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIGURATION="${1:-debug}"
BUILD_DIR="$PROJECT_DIR/Build"
APP_DIR="$BUILD_DIR/ScreenTrace.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cd "$PROJECT_DIR"
swift build -c "$CONFIGURATION" --product ScreenTrace
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN_DIR/ScreenTrace" "$MACOS_DIR/ScreenTrace"

PLIST_PATH="$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Clear dict" "$PLIST_PATH" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleDevelopmentRegion string zh_CN" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string 屏迹" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string ScreenTrace" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string app.screentrace.mac" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFBundleInfoDictionaryVersion string 6.0" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFBundleName string ScreenTrace" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 0.1.0" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string 1" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 15.2" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :NSHighResolutionCapable bool true" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :NSMicrophoneUsageDescription string 屏迹仅在你主动录屏时使用麦克风。" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :NSCameraUsageDescription string 屏迹仅在你主动开启摄像头录制时使用摄像头。" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :NSSpeechRecognitionUsageDescription string 屏迹仅在你主动生成转写或字幕时使用本机语音识别。" "$PLIST_PATH"

codesign --force --deep --sign - "$APP_DIR"
echo "$APP_DIR"
