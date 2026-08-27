#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLOSE_AFTER_SECONDS="${1:-8}"
REPORT_PATH="${2:-$PROJECT_DIR/Build/Quality/g2-source-interruption-latest.json}"
EXECUTABLE="/Applications/Lens.app/Contents/MacOS/Lens"

[[ "$CLOSE_AFTER_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
    echo "Close-after seconds must be a number between 5 and 30." >&2
    exit 64
}
if [[ ! -x "$EXECUTABLE" ]]; then
    echo "Missing installed Lens executable." >&2
    exit 66
fi
if pgrep -x Lens >/dev/null 2>&1; then
    echo "Lens is already running." >&2
    exit 73
fi

cd "$PROJECT_DIR"
"$EXECUTABLE" \
    --g2-source-interruption \
    --close-after-seconds "$CLOSE_AFTER_SECONDS" \
    --callback-timeout-seconds 12 \
    --report "$REPORT_PATH"

RESULT="$(plutil -extract result raw -o - "$REPORT_PATH")"
[[ "$RESULT" == "passed" ]] || {
    echo "G2 source interruption did not pass: $REPORT_PATH" >&2
    exit 65
}

echo "G2 source interruption passed: $REPORT_PATH"
