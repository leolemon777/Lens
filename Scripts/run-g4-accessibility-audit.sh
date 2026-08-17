#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPORT_PATH="${1:-$PROJECT_DIR/Build/Quality/g4-accessibility-runtime-latest.json}"
EXECUTABLE="/Applications/ScreenTrace.app/Contents/MacOS/ScreenTrace"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ScreenTrace-g4-ax.XXXXXX")"
READY_MARKER="$TEMP_ROOT/ready.marker"
HOST_PID=""

cleanup() {
    if [[ "$HOST_PID" =~ ^[0-9]+$ ]] && kill -0 "$HOST_PID" 2>/dev/null; then
        kill -TERM "$HOST_PID" 2>/dev/null || true
        wait "$HOST_PID" 2>/dev/null || true
    fi
    find "$TEMP_ROOT" -depth -delete
}
trap cleanup EXIT

mkdir -p "$(dirname "$REPORT_PATH")"

if ioreg -n Root -d1 | grep -F 'CGSSessionScreenIsLocked"=Yes' >/dev/null; then
    plutil -create xml1 "$REPORT_PATH"
    plutil -insert schemaVersion -integer 1 "$REPORT_PATH"
    plutil -insert gate -string G4-accessibility-runtime "$REPORT_PATH"
    plutil -insert result -string blocked "$REPORT_PATH"
    plutil -insert reason -string screenLocked "$REPORT_PATH"
    plutil -insert generatedAt -string "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$REPORT_PATH"
    plutil -insert evidenceLevel -string E4-installed-native-app-system-AX "$REPORT_PATH"
    plutil -convert json "$REPORT_PATH"
    echo "G4 accessibility runtime audit blocked: unlock the desktop." >&2
    exit 77
fi

[[ -x "$EXECUTABLE" ]] || { echo "Missing installed ScreenTrace executable." >&2; exit 66; }
if pgrep -x ScreenTrace >/dev/null 2>&1; then
    echo "ScreenTrace is already running. Quit it before the isolated G4 audit." >&2
    exit 73
fi

"$EXECUTABLE" --g4-accessibility-host --ready-marker "$READY_MARKER" &
HOST_PID=$!
for _ in {1..80}; do
    [[ -f "$READY_MARKER" ]] && break
    kill -0 "$HOST_PID" 2>/dev/null || { echo "G4 host exited before ready." >&2; exit 65; }
    sleep 0.1
done
[[ -f "$READY_MARKER" ]] || { echo "G4 host did not become ready." >&2; exit 65; }
sleep 0.4

xcrun swift "$SCRIPT_DIR/g4-accessibility-audit.swift" \
    --pid "$HOST_PID" \
    --report "$REPORT_PATH"

[[ "$(plutil -extract result raw -o - "$REPORT_PATH")" == "passed" ]] \
    || { echo "G4 accessibility runtime audit failed: $REPORT_PATH" >&2; exit 65; }
echo "G4 accessibility runtime audit passed: $REPORT_PATH"
