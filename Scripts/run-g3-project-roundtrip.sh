#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TRACE_PACKAGE="${1:-}"
REPORT_PATH="${2:-$PROJECT_DIR/Build/Quality/g3-project-roundtrip-installed-source.json}"
APP_PATH="${LENS_APP_PATH:-/Applications/Lens.app}"
EXECUTABLE="$APP_PATH/Contents/MacOS/Lens"

if [[ -z "$TRACE_PACKAGE" ]]; then
    echo "Usage: $0 <recording.lens> [report.json]" >&2
    exit 64
fi
if [[ ! -d "$TRACE_PACKAGE" ]]; then
    echo "Missing recording project: $TRACE_PACKAGE" >&2
    exit 66
fi
if [[ ! -x "$EXECUTABLE" ]]; then
    echo "Missing installed Lens executable: $EXECUTABLE" >&2
    exit 66
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
mkdir -p "$(dirname "$REPORT_PATH")"

"$EXECUTABLE" \
    --g3-rendered-effects \
    --project "$TRACE_PACKAGE" \
    --report "$REPORT_PATH" \
    --preset source \
    --enable-captions \
    --caption-text "保存重开后，字幕与标注必须进入最终成片" \
    --add-video-annotation \
    --persist-derived-copy \
    --require-effects "captions,videoAnnotation"

echo "G3 project round-trip passed: $REPORT_PATH"
