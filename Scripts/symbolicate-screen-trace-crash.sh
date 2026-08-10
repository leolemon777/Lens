#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 /path/to/ScreenTrace.ips /path/to/ScreenTrace.dSYM" >&2
    exit 64
fi

REPORT_PATH="$1"
DSYM_PATH="$2"
DWARF_PATH="$DSYM_PATH/Contents/Resources/DWARF/ScreenTrace"

if [[ ! -f "$REPORT_PATH" || "${REPORT_PATH##*.}" != "ips" ]]; then
    echo "Crash report must be a regular .ips file" >&2
    exit 65
fi
if [[ -L "$REPORT_PATH" ]]; then
    echo "Refusing symbolic-link crash report" >&2
    exit 65
fi
if [[ ! -f "$DWARF_PATH" ]]; then
    echo "Missing ScreenTrace DWARF binary: $DWARF_PATH" >&2
    exit 66
fi

HEADER_JSON="$(sed -n '1p' "$REPORT_PATH")"
BUNDLE_ID="$(jq -er '.bundleID' <<<"$HEADER_JSON")"
APP_NAME="$(jq -er '.app_name' <<<"$HEADER_JSON")"
CRASH_UUID="$(jq -er '.slice_uuid | ascii_upcase' <<<"$HEADER_JSON")"
if [[ "$BUNDLE_ID" != "app.screentrace.mac" || "$APP_NAME" != "ScreenTrace" ]]; then
    echo "Crash report does not belong to ScreenTrace" >&2
    exit 65
fi

DSYM_UUID="$(xcrun dwarfdump --uuid "$DSYM_PATH" | awk 'NR == 1 { print toupper($2) }')"
if [[ -z "$DSYM_UUID" || "$CRASH_UUID" != "$DSYM_UUID" ]]; then
    echo "dSYM UUID mismatch: crash=$CRASH_UUID symbols=$DSYM_UUID" >&2
    exit 67
fi

BODY_JSON="$(sed '1d' "$REPORT_PATH")"
CRASH_UUID_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"$CRASH_UUID")"
IMAGE_INDEX="$(jq -er --arg uuid "$CRASH_UUID_LOWER" '
    .usedImages | to_entries[]
    | select((.value.uuid | ascii_downcase) == $uuid)
    | .key
' <<<"$BODY_JSON" | head -1)"
LOAD_ADDRESS="$(jq -er --argjson index "$IMAGE_INDEX" '.usedImages[$index].base' <<<"$BODY_JSON")"
ARCHITECTURE="$(jq -er --argjson index "$IMAGE_INDEX" '.usedImages[$index].arch' <<<"$BODY_JSON")"
FAULTING_THREAD="$(jq -er '.faultingThread' <<<"$BODY_JSON")"

IMAGE_OFFSETS="$(jq -r \
    --argjson thread "$FAULTING_THREAD" \
    --argjson image "$IMAGE_INDEX" '
        .threads[$thread].frames[]
        | select(.imageIndex == $image)
        | .imageOffset
    ' <<<"$BODY_JSON")"

echo "Incident: $(jq -er '.incident_id' <<<"$HEADER_JSON")"
echo "Crash UUID: $CRASH_UUID"
echo "dSYM UUID: $DSYM_UUID"
echo "Faulting thread: $FAULTING_THREAD"

if [[ -z "$IMAGE_OFFSETS" ]]; then
    echo "No ScreenTrace frames on the faulting thread"
    exit 0
fi

FRAME_NUMBER=0
while IFS= read -r OFFSET; do
    ADDRESS=$((LOAD_ADDRESS + OFFSET))
    SYMBOL="$(xcrun atos \
        -arch "$ARCHITECTURE" \
        -o "$DWARF_PATH" \
        -l "$LOAD_ADDRESS" \
        "$ADDRESS")"
    printf '#%d 0x%x %s\n' "$FRAME_NUMBER" "$ADDRESS" "$SYMBOL"
    FRAME_NUMBER=$((FRAME_NUMBER + 1))
done <<<"$IMAGE_OFFSETS"
