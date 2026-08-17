#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_PATH="${SCREENTRACE_APP_PATH:-/Applications/ScreenTrace.app}"
REPORT_PATH="${1:-$PROJECT_DIR/Build/Quality/g3-transcription-controlled-installed.json}"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ScreenTrace-g3-transcription.XXXXXX")"
AUDIO_PATH="$TEMP_ROOT/controlled-speech.aiff"

cleanup() {
    rm -rf -- "$TEMP_ROOT"
}
trap cleanup EXIT

if [[ ! -d "$APP_PATH" ]]; then
    echo "Missing installed app: $APP_PATH" >&2
    exit 66
fi
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
usage_description="$(/usr/libexec/PlistBuddy \
    -c 'Print :NSSpeechRecognitionUsageDescription' \
    "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
if [[ -z "$usage_description" ]]; then
    echo "Installed app is missing NSSpeechRecognitionUsageDescription." >&2
    exit 65
fi
if ! say -v '?' | grep -Fq 'Tingting'; then
    echo "The controlled zh-CN Tingting system voice is unavailable." >&2
    exit 69
fi

mkdir -p "$(dirname "$REPORT_PATH")"
say -v Tingting -r 165 -o "$AUDIO_PATH" \
    '屏幕录制，自动字幕，光标点击。屏迹让演示视频更加清晰流畅。'

# Speech privacy access must be initiated through LaunchServices. Invoking the
# Mach-O directly bypasses the bundle's privacy metadata and macOS terminates it.
open -W -n "$APP_PATH" --args \
    --g3-transcription \
    --audio "$AUDIO_PATH" \
    --report "$REPORT_PATH" \
    --locale zh-CN \
    --expected-terms '屏幕,录制,字幕,光标,点击,演示,视频,清晰' \
    --verify-organization

jq -e '
    .result == "passed"
    and .evidenceLevel == "E4-installed-native-app"
    and .isOnDevice == true
    and .timelineIsValid == true
    and .segmentCount > 0
    and .recognizedCharacterCount > 0
    and .expectedTermCount == .matchedExpectedTermCount
    and .organizationRequired == true
    and .organizationVerified == true
    and .organizationTagCount > 0
    and .organizationChapterCount > 0
' "$REPORT_PATH" >/dev/null
echo "G3 on-device transcription and organization passed: $REPORT_PATH"
