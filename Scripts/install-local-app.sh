#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_APP="${1:-$PROJECT_DIR/Build/Lens.app}"
TARGET_APP="/Applications/Lens.app"
STAGING_APP="/Applications/.Lens.install.$$.app"
BACKUP_ROOT="$PROJECT_DIR/Build/InstallBackups"
BACKUP_APP=""
INSTALL_SUCCEEDED=0

cleanup() {
    if [[ -e "$STAGING_APP" ]]; then
        rm -rf -- "$STAGING_APP"
    fi
    if [[ "$INSTALL_SUCCEEDED" -eq 0 && -n "$BACKUP_APP" && -e "$BACKUP_APP" && ! -e "$TARGET_APP" ]]; then
        mv -- "$BACKUP_APP" "$TARGET_APP"
    fi
}
trap cleanup EXIT

if [[ "$TARGET_APP" != "/Applications/Lens.app" ]]; then
    echo "Refusing unexpected install target: $TARGET_APP" >&2
    exit 64
fi
if [[ ! -d "$SOURCE_APP" ]]; then
    echo "Missing source app: $SOURCE_APP" >&2
    exit 66
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE_APP/Contents/Info.plist" 2>/dev/null || true)" != "app.lens.mac" ]]; then
    echo "Source app has an unexpected bundle identifier." >&2
    exit 65
fi
if pgrep -x Lens >/dev/null 2>&1; then
    echo "Lens is running. Stop any recording and quit the app before installing." >&2
    exit 73
fi

codesign --verify --deep --strict --verbose=2 "$SOURCE_APP"
mkdir -p "$BACKUP_ROOT"
/usr/bin/ditto "$SOURCE_APP" "$STAGING_APP"
codesign --verify --deep --strict --verbose=2 "$STAGING_APP"

if [[ -e "$TARGET_APP" ]]; then
    BACKUP_APP="$BACKUP_ROOT/Lens-$(date -u +%Y%m%dT%H%M%SZ).app"
    mv -- "$TARGET_APP" "$BACKUP_APP"
fi
mv -- "$STAGING_APP" "$TARGET_APP"

if ! "$SCRIPT_DIR/verify-installed-app.sh" "$SOURCE_APP" "$TARGET_APP"; then
    FAILED_APP="$BACKUP_ROOT/Failed-Lens-$(date -u +%Y%m%dT%H%M%SZ).app"
    mv -- "$TARGET_APP" "$FAILED_APP"
    if [[ -n "$BACKUP_APP" && -e "$BACKUP_APP" ]]; then
        mv -- "$BACKUP_APP" "$TARGET_APP"
        BACKUP_APP=""
    fi
    echo "Installation verification failed. The previous app was restored." >&2
    exit 65
fi

INSTALL_SUCCEEDED=1
echo "Installed and verified: $TARGET_APP"
if [[ -n "$BACKUP_APP" ]]; then
    echo "Recoverable previous build: $BACKUP_APP"
fi
