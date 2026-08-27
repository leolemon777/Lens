#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CAPTURE_SECONDS="${1:-30}"
REPORT_PATH="${2:-$PROJECT_DIR/Build/Quality/g2-recording-disk-exhaustion-latest.json}"
EXECUTABLE="/Applications/Lens.app/Contents/MacOS/Lens"
MOUNT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/Lens-g2-disk.XXXXXX")"
IMAGE_WORK_DIR="$(mktemp -d "$PROJECT_DIR/Build/Quality/g2-disk-image.XXXXXX")"
IMAGE_PATH="$IMAGE_WORK_DIR/fault.dmg"
FILLER_PATH="$MOUNT_DIR/reserved-space.bin"
WORK_ROOT="$MOUNT_DIR/work"
SEED_REPORT="$PROJECT_DIR/Build/Quality/g2-recording-disk-exhaustion-seed.json"
RECOVERY_REPORT="$PROJECT_DIR/Build/Quality/g2-recording-disk-exhaustion-recovery.json"
IS_MOUNTED=0

cleanup() {
    if [[ "$IS_MOUNTED" == "1" ]]; then
        hdiutil detach "$MOUNT_DIR" -quiet 2>/dev/null || true
        IS_MOUNTED=0
    fi
    if [[ -f "$IMAGE_PATH" ]]; then unlink "$IMAGE_PATH"; fi
    if [[ -d "$IMAGE_WORK_DIR" ]]; then rmdir "$IMAGE_WORK_DIR" 2>/dev/null || true; fi
    if [[ -d "$MOUNT_DIR" ]]; then rmdir "$MOUNT_DIR" 2>/dev/null || true; fi
}
trap cleanup EXIT

[[ "$CAPTURE_SECONDS" =~ ^[0-9]+$ ]] && (( CAPTURE_SECONDS >= 20 && CAPTURE_SECONDS <= 120 )) || {
    echo "Capture seconds must be an integer between 20 and 120." >&2
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
case "$REPORT_PATH" in
    /*) ;;
    *) REPORT_PATH="$PROJECT_DIR/$REPORT_PATH" ;;
esac
mkdir -p "$(dirname "$REPORT_PATH")"

# Use a disposable, size-bounded filesystem so ENOSPC is genuine without
# consuming the user's real project volume. Keep a removable reservation:
# after the writer fails, releasing it gives recovery enough room to remux.
hdiutil create -quiet -size 256m -fs HFS+J \
    -volname LensG2DiskFault "$IMAGE_PATH"
hdiutil attach -quiet -nobrowse -mountpoint "$MOUNT_DIR" "$IMAGE_PATH"
IS_MOUNTED=1

AVAILABLE_KB="$(df -k "$MOUNT_DIR" | awk 'NR == 2 { print $4 }')"
TARGET_FREE_KB=24576
if (( AVAILABLE_KB <= TARGET_FREE_KB + 8192 )); then
    echo "Disposable volume does not have enough capacity for the fault gate." >&2
    exit 65
fi
FILL_KB=$((AVAILABLE_KB - TARGET_FREE_KB))
/usr/sbin/mkfile "${FILL_KB}k" "$FILLER_PATH"
FREE_BEFORE_BYTES=$(( $(df -k "$MOUNT_DIR" | awk 'NR == 2 { print $4 }') * 1024 ))

set +e
"$EXECUTABLE" \
    --g2-recording-stress \
    --duration-seconds "$CAPTURE_SECONDS" \
    --fps 60 \
    --work-root "$WORK_ROOT" \
    --report "$SEED_REPORT"
SEED_STATUS=$?
set -e

if [[ "$SEED_STATUS" == "0" ]]; then
    echo "Disposable volume did not exhaust as intended." >&2
    exit 65
fi
SEED_RESULT="$(plutil -extract result raw -o - "$SEED_REPORT")"
SEED_REASON="$(plutil -extract reason raw -o - "$SEED_REPORT" 2>/dev/null || true)"
SEED_ERROR="$(plutil -extract errorDescription raw -o - "$SEED_REPORT" 2>/dev/null || true)"
AUDIO_SEGMENT_COUNT="$(find "$WORK_ROOT" -type f -name '*.caf' \
    ! -name '*.partial.caf' | wc -l | tr -d ' ')"
AUDIO_SEGMENT_BYTES="$(find "$WORK_ROOT" -type f -name '*.caf' \
    ! -name '*.partial.caf' -exec stat -f '%z' {} + \
    | awk '{ total += $1 } END { print total + 0 }')"
PARTIAL_AUDIO_COUNT="$(find "$WORK_ROOT" -type f -name '*.partial.caf' \
    | wc -l | tr -d ' ')"

unlink "$FILLER_PATH"
sync
FREE_FOR_RECOVERY_BYTES=$(( $(df -k "$MOUNT_DIR" | awk 'NR == 2 { print $4 }') * 1024 ))

set +e
"$EXECUTABLE" \
    --g2-recording-recovery \
    --work-root "$WORK_ROOT" \
    --expected-duration-seconds "$CAPTURE_SECONDS" \
    --fault ENOSPC \
    --allow-early-writer-failure \
    --accept-already-interrupted \
    --report "$RECOVERY_REPORT"
RECOVERY_STATUS=$?
set -e
RECOVERY_RESULT="$(plutil -extract result raw -o - "$RECOVERY_REPORT")"
RECOVERED_DURATION="$(plutil -extract recoveredDurationSeconds raw -o - "$RECOVERY_REPORT" 2>/dev/null || echo 0)"
TRACKS_VERIFIED="$(plutil -extract checks.physicalTracksVerified raw -o - "$RECOVERY_REPORT" 2>/dev/null || echo false)"
AUDIO_NON_SILENT="$(plutil -extract checks.systemAudioNonSilent raw -o - "$RECOVERY_REPORT" 2>/dev/null || echo false)"
FINAL_RESULT=failed
WRITER_FAILED_ON_BOUNDED_VOLUME=false
RECOVERED_AFTER_FREEING_SPACE=false
if [[ "$SEED_STATUS" != "0" && "$SEED_RESULT" == "failed" \
    && "$SEED_ERROR" == *"空间不足"* ]]; then
    WRITER_FAILED_ON_BOUNDED_VOLUME=true
fi
if [[ "$RECOVERY_STATUS" == "0" && "$RECOVERY_RESULT" == "passed" \
    && "$TRACKS_VERIFIED" == "true" && "$AUDIO_NON_SILENT" == "true" ]]; then
    RECOVERED_AFTER_FREEING_SPACE=true
    FINAL_RESULT=passed
fi

plutil -create xml1 "$REPORT_PATH"
plutil -insert schemaVersion -integer 1 "$REPORT_PATH"
plutil -insert gate -string G2-disk-exhaustion "$REPORT_PATH"
plutil -insert result -string "$FINAL_RESULT" "$REPORT_PATH"
plutil -insert fault -string ENOSPC "$REPORT_PATH"
plutil -insert evidenceLevel -string E4-installed-native-app-bounded-volume "$REPORT_PATH"
plutil -insert requestedCaptureSeconds -integer "$CAPTURE_SECONDS" "$REPORT_PATH"
plutil -insert freeBytesBeforeCapture -integer "$FREE_BEFORE_BYTES" "$REPORT_PATH"
plutil -insert freeBytesBeforeRecovery -integer "$FREE_FOR_RECOVERY_BYTES" "$REPORT_PATH"
plutil -insert seedProcessExitStatus -integer "$SEED_STATUS" "$REPORT_PATH"
plutil -insert seedResult -string "$SEED_RESULT" "$REPORT_PATH"
plutil -insert seedReason -string "$SEED_REASON" "$REPORT_PATH"
plutil -insert seedErrorDescription -string "$SEED_ERROR" "$REPORT_PATH"
plutil -insert completedAudioSegmentCount -integer "$AUDIO_SEGMENT_COUNT" "$REPORT_PATH"
plutil -insert completedAudioSegmentBytes -integer "$AUDIO_SEGMENT_BYTES" "$REPORT_PATH"
plutil -insert partialAudioSegmentCount -integer "$PARTIAL_AUDIO_COUNT" "$REPORT_PATH"
plutil -insert recoveryResult -string "$RECOVERY_RESULT" "$REPORT_PATH"
plutil -insert recoveryProcessExitStatus -integer "$RECOVERY_STATUS" "$REPORT_PATH"
plutil -insert recoveredDurationSeconds -float "$RECOVERED_DURATION" "$REPORT_PATH"
plutil -insert checks -dictionary "$REPORT_PATH"
plutil -insert checks.writerFailedOnBoundedVolume -bool \
    "$WRITER_FAILED_ON_BOUNDED_VOLUME" "$REPORT_PATH"
plutil -insert checks.recoveredAfterFreeingSpace -bool \
    "$RECOVERED_AFTER_FREEING_SPACE" "$REPORT_PATH"
plutil -insert checks.physicalTracksVerified -bool "$TRACKS_VERIFIED" "$REPORT_PATH"
plutil -insert checks.systemAudioNonSilent -bool "$AUDIO_NON_SILENT" "$REPORT_PATH"
plutil -convert json "$REPORT_PATH"

if [[ "$FINAL_RESULT" != "passed" ]]; then
    echo "G2 bounded-volume ENOSPC recovery failed: $REPORT_PATH" >&2
    exit 65
fi
echo "G2 bounded-volume ENOSPC recovery passed: $REPORT_PATH"
