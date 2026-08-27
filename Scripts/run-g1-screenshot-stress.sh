#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ITERATIONS="${1:-100}"
REPORT_PATH="${2:-$PROJECT_DIR/Build/Quality/g1-screenshot-stress-latest.json}"
APP_PATH="$PROJECT_DIR/Build/Lens.app"

[[ "$ITERATIONS" =~ ^[0-9]+$ ]] && (( ITERATIONS >= 1 && ITERATIONS <= 1000 )) || {
    echo "Iterations must be an integer between 1 and 1000." >&2
    exit 64
}

cd "$PROJECT_DIR"
bash Scripts/build-app.sh release
"$APP_PATH/Contents/MacOS/Lens" \
    --g1-screenshot-stress \
    --iterations "$ITERATIONS" \
    --report "$REPORT_PATH"

RESULT="$(plutil -extract result raw -o - "$REPORT_PATH")"
SUCCEEDED="$(plutil -extract successfulIterations raw -o - "$REPORT_PATH")"
[[ "$RESULT" == "passed" && "$SUCCEEDED" == "$ITERATIONS" ]] || {
    echo "G1 screenshot stress did not pass: $REPORT_PATH" >&2
    exit 65
}

echo "G1 screenshot stress passed ($SUCCEEDED/$ITERATIONS): $REPORT_PATH"
