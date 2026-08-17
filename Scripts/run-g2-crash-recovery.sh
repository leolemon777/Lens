#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CAPTURE_SECONDS="${1:-17}"
REPORT_PATH="${2:-$PROJECT_DIR/Build/Quality/g2-recording-crash-recovery-latest.json}"
EXECUTABLE="/Applications/ScreenTrace.app/Contents/MacOS/ScreenTrace"
WORK_ROOT="$(mktemp -d "$PROJECT_DIR/Build/Quality/g2-crash-work.XXXXXX")"
READY_MARKER="$WORK_ROOT/ready.marker"
SEED_REPORT="$WORK_ROOT/seed-should-not-complete.json"
SEED_PID=""
TONE_PID=""

stop_tone_process() {
    if [[ "$TONE_PID" =~ ^[0-9]+$ ]] && kill -0 "$TONE_PID" 2>/dev/null; then
        kill -TERM "$TONE_PID" 2>/dev/null || true
        for _ in {1..20}; do
            if ! kill -0 "$TONE_PID" 2>/dev/null; then break; fi
            sleep 0.05
        done
        if kill -0 "$TONE_PID" 2>/dev/null; then
            kill -KILL "$TONE_PID" 2>/dev/null || true
        fi
    fi
    TONE_PID=""
}

cleanup() {
    if [[ -n "$SEED_PID" ]] && kill -0 "$SEED_PID" 2>/dev/null; then
        kill -KILL "$SEED_PID" 2>/dev/null || true
        wait "$SEED_PID" 2>/dev/null || true
    fi
    stop_tone_process
    if [[ -d "$WORK_ROOT" ]]; then
        rm -rf -- "$WORK_ROOT"
    fi
}
trap cleanup EXIT

[[ "$CAPTURE_SECONDS" =~ ^[0-9]+$ ]] && (( CAPTURE_SECONDS >= 12 && CAPTURE_SECONDS <= 120 )) || {
    echo "Capture seconds must be an integer between 12 and 120." >&2
    exit 64
}
if [[ ! -x "$EXECUTABLE" ]]; then
    echo "Missing installed ScreenTrace executable." >&2
    exit 66
fi
if pgrep -x ScreenTrace >/dev/null 2>&1; then
    echo "ScreenTrace is already running." >&2
    exit 73
fi

"$EXECUTABLE" \
    --g2-recording-stress \
    --duration-seconds 3600 \
    --fps 60 \
    --work-root "$WORK_ROOT" \
    --ready-marker "$READY_MARKER" \
    --report "$SEED_REPORT" &
SEED_PID=$!

for _ in {1..120}; do
    if [[ -f "$READY_MARKER" ]]; then break; fi
    if ! kill -0 "$SEED_PID" 2>/dev/null; then
        echo "Crash seed exited before recording became ready." >&2
        exit 65
    fi
    sleep 0.25
done
if [[ ! -f "$READY_MARKER" ]]; then
    echo "Crash seed did not become ready." >&2
    exit 65
fi

sleep "$CAPTURE_SECONDS"
TONE_PID="$(pgrep -P "$SEED_PID" -x afplay | head -n 1 || true)"
kill -KILL "$SEED_PID"
wait "$SEED_PID" 2>/dev/null || true
SEED_PID=""
stop_tone_process

"$EXECUTABLE" \
    --g2-recording-recovery \
    --work-root "$WORK_ROOT" \
    --expected-duration-seconds "$CAPTURE_SECONDS" \
    --report "$REPORT_PATH"

RESULT="$(plutil -extract result raw -o - "$REPORT_PATH")"
[[ "$RESULT" == "passed" ]] || {
    echo "G2 crash recovery did not pass: $REPORT_PATH" >&2
    exit 65
}

echo "G2 SIGKILL recovery passed: $REPORT_PATH"
