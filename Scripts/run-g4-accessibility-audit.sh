#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPORT_PATH="${1:-$PROJECT_DIR/Build/Quality/g4-accessibility-runtime-latest.json}"
APP_PATH="${LENS_APP_PATH:-/Applications/Lens.app}"
EXECUTABLE="$APP_PATH/Contents/MacOS/Lens"
EVIDENCE_LEVEL="E4-installed-native-app-system-AX"
AUDIT_ARGUMENTS=()
if [[ "$APP_PATH" != "/Applications/Lens.app" ]]; then
    EVIDENCE_LEVEL="E2-candidate-native-app-system-AX"
fi
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/Lens-g4-ax.XXXXXX")"
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
    plutil -insert evidenceLevel -string "$EVIDENCE_LEVEL" "$REPORT_PATH"
    plutil -convert json "$REPORT_PATH"
    echo "G4 accessibility runtime audit blocked: unlock the desktop." >&2
    exit 77
fi

[[ -x "$EXECUTABLE" ]] || { echo "Missing installed Lens executable." >&2; exit 66; }
if [[ "$APP_PATH" == "/Applications/Lens.app" ]] \
    && pgrep -x Lens >/dev/null 2>&1; then
    echo "The installed Lens is already running. Quit it before the installed G4 audit." >&2
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
# SwiftUI's accessibility tree can publish the window shell before all hosted
# controls have finished materializing. Keep the runtime audit deterministic by
# allowing one short stabilization window after the ready marker.
sleep 0.8

AUDIT_ARGUMENTS=(
    --pid "$HOST_PID"
    --report "$REPORT_PATH"
    --evidence-level "$EVIDENCE_LEVEL"
)
if [[ "$APP_PATH" != "/Applications/Lens.app" ]]; then
    CANDIDATE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
    CANDIDATE_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
    AUDIT_ARGUMENTS+=(
        --candidate-app "$APP_PATH"
        --candidate-version "$CANDIDATE_VERSION"
        --candidate-build "$CANDIDATE_BUILD"
    )
fi
xcrun swift "$SCRIPT_DIR/g4-accessibility-audit.swift" "${AUDIT_ARGUMENTS[@]}"

[[ "$(plutil -extract result raw -o - "$REPORT_PATH")" == "passed" ]] \
    || { echo "G4 accessibility runtime audit failed: $REPORT_PATH" >&2; exit 65; }
echo "G4 accessibility runtime audit passed: $REPORT_PATH"
