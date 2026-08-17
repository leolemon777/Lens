#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DURATION_SECONDS="${1:-60}"
FPS="${2:-60}"
REPORT_PATH="${3:-$PROJECT_DIR/Build/Quality/g2-recording-stress-latest.json}"
APP_PATH="$PROJECT_DIR/Build/ScreenTrace.app"

[[ "$DURATION_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
    echo "Duration must be a number between 5 and 7200 seconds." >&2
    exit 64
}
[[ "$FPS" == "30" || "$FPS" == "60" ]] || {
    echo "FPS must be 30 or 60." >&2
    exit 64
}

cd "$PROJECT_DIR"
bash Scripts/build-app.sh release
"$APP_PATH/Contents/MacOS/ScreenTrace" \
    --g2-recording-stress \
    --duration-seconds "$DURATION_SECONDS" \
    --fps "$FPS" \
    --report "$REPORT_PATH"

RESULT="$(plutil -extract result raw -o - "$REPORT_PATH")"
[[ "$RESULT" == "passed" ]] || {
    echo "G2 recording stress did not pass: $REPORT_PATH" >&2
    exit 65
}

echo "G2 recording stress passed: $REPORT_PATH"
