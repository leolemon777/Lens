#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TRACE_PACKAGE="${1:-}"
REPORT_DIR="${2:-$PROJECT_DIR/Build/Quality}"
APP_PATH="${SCREENTRACE_APP_PATH:-/Applications/ScreenTrace.app}"
EXECUTABLE="$APP_PATH/Contents/MacOS/ScreenTrace"

if [[ -z "$TRACE_PACKAGE" ]]; then
    echo "Usage: $0 <recording.screentrace> [report-directory]" >&2
    exit 64
fi
if [[ ! -d "$TRACE_PACKAGE" ]]; then
    echo "Missing recording project: $TRACE_PACKAGE" >&2
    exit 66
fi
if [[ ! -x "$EXECUTABLE" ]]; then
    echo "Missing installed ScreenTrace executable: $EXECUTABLE" >&2
    exit 66
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
mkdir -p "$REPORT_DIR"

for preset in source balanced compact; do
    report="$REPORT_DIR/g3-real-effects-installed-$preset.json"
    "$EXECUTABLE" \
        --g3-rendered-effects \
        --project "$TRACE_PACKAGE" \
        --report "$report" \
        --preset "$preset"
    echo "G3 $preset passed: $report"
done
