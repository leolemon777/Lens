#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPORT_DIR="${1:-$PROJECT_DIR/Build/Quality}"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/Lens-g0.XXXXXX")"
TEST_LOG="$TEMP_ROOT/swift-test.log"
BUILD_LOG="$TEMP_ROOT/swift-build.log"
REPORT_PATH="$REPORT_DIR/g0-baseline-latest.json"
PERFORMANCE_PATH="$REPORT_DIR/capture-performance-latest.json"

cleanup() {
    find "$TEMP_ROOT" -depth -delete
}
trap cleanup EXIT

mkdir -p "$REPORT_DIR"
cd "$PROJECT_DIR"
SOURCE_SNAPSHOT_BEFORE="$(bash Scripts/source-snapshot-digest.sh "$PROJECT_DIR")"

set -o pipefail
swift test 2>&1 | tee "$TEST_LOG"
swift build -c release --product Lens -Xswiftc -warnings-as-errors 2>&1 \
    | tee "$BUILD_LOG"
bash Scripts/build-app.sh release
codesign --verify --deep --strict --verbose=2 Build/Lens.app
bash Scripts/audit-public-source.sh
bash Scripts/test-source-snapshot-digest.sh
swift Scripts/summarize-capture-performance.swift "$PERFORMANCE_PATH"
SOURCE_SNAPSHOT_AFTER="$(bash Scripts/source-snapshot-digest.sh "$PROJECT_DIR")"
if [[ "$SOURCE_SNAPSHOT_AFTER" != "$SOURCE_SNAPSHOT_BEFORE" ]]; then
    echo "Source snapshot changed while the G0 baseline was running." >&2
    exit 65
fi

TEST_COUNT="$(awk '
    /Executed [0-9]+ tests, with 0 failures/ { count = $2 }
    END { if (count != "") print count }
' "$TEST_LOG")"
[[ "$TEST_COUNT" =~ ^[0-9]+$ ]] || {
    echo "Could not determine the passing test count." >&2
    exit 65
}

OS_VERSION="$(sw_vers -productVersion)"
ARCHITECTURE="$(uname -m)"
MODEL_IDENTIFIER="$(sysctl -n hw.model)"
MEMORY_BYTES="$(sysctl -n hw.memsize)"
CHIP="$(system_profiler SPHardwareDataType \
    | awk -F ': ' '/^[[:space:]]+Chip:/ { print $2; exit }')"
DISPLAY_RESOLUTIONS="$(system_profiler SPDisplaysDataType \
    | awk -F ': ' '/^[[:space:]]+Resolution:/ { values = values sep $2; sep = ", " } END { print values }')"
GIT_COMMIT="$(git rev-parse HEAD)"
if [[ -n "$(git status --porcelain)" ]]; then
    GIT_WORKTREE="dirty"
else
    GIT_WORKTREE="clean"
fi
GENERATED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

escape_json() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

cat > "$REPORT_PATH" <<REPORT
{
  "schemaVersion": 1,
  "generatedAt": "$(escape_json "$GENERATED_AT")",
  "gate": "G0",
  "result": "passed",
  "automatedTests": {
    "count": $TEST_COUNT,
    "failures": 0
  },
  "releaseBuild": {
    "configuration": "release",
    "warningsAsErrors": true,
    "bundleSignatureVerified": true
  },
  "sourceSnapshotDigestRegression": true,
  "environment": {
    "macOS": "$(escape_json "$OS_VERSION")",
    "architecture": "$(escape_json "$ARCHITECTURE")",
    "modelIdentifier": "$(escape_json "$MODEL_IDENTIFIER")",
    "chip": "$(escape_json "$CHIP")",
    "memoryBytes": $MEMORY_BYTES,
    "displayResolutions": "$(escape_json "$DISPLAY_RESOLUTIONS")"
  },
  "source": {
    "gitCommit": "$(escape_json "$GIT_COMMIT")",
    "worktree": "$(escape_json "$GIT_WORKTREE")",
    "sourceSnapshotSHA256": "$(escape_json "$SOURCE_SNAPSHOT_AFTER")"
  },
  "scenarioManifest": "Config/G0BaselineScenarios.json",
  "performanceReport": "capture-performance-latest.json"
}
REPORT

plutil -convert binary1 -o /dev/null "$REPORT_PATH"
plutil -convert binary1 -o /dev/null "$PERFORMANCE_PATH"
echo "G0 baseline passed: $REPORT_PATH"
