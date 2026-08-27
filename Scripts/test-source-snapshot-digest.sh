#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/Lens-source-digest-test.XXXXXX")"

cleanup() {
    if [[ -d "$TEMP_ROOT" ]]; then
        find "$TEMP_ROOT" -depth -delete
    fi
}
trap cleanup EXIT

cd "$TEMP_ROOT"
git init -q
printf 'ignored.txt\n' > .gitignore
printf 'tracked-v1\n' > tracked.txt
git add .gitignore tracked.txt

digest() {
    "$SCRIPT_DIR/source-snapshot-digest.sh" "$TEMP_ROOT"
}

BASELINE="$(digest)"

printf 'ignored-content\n' > ignored.txt
[[ "$(digest)" == "$BASELINE" ]] || {
    echo "Ignored artifacts changed the source snapshot digest." >&2
    exit 65
}

printf 'tracked-v2\n' > tracked.txt
TRACKED_CHANGED="$(digest)"
[[ "$TRACKED_CHANGED" != "$BASELINE" ]] || {
    echo "A tracked file modification did not change the digest." >&2
    exit 65
}

printf 'tracked-v1\n' > tracked.txt
printf 'untracked\n' > untracked.txt
UNTRACKED_CHANGED="$(digest)"
[[ "$UNTRACKED_CHANGED" != "$BASELINE" ]] || {
    echo "An untracked source file did not change the digest." >&2
    exit 65
}

unlink untracked.txt
unlink tracked.txt
DELETED_CHANGED="$(digest)"
[[ "$DELETED_CHANGED" != "$BASELINE" ]] || {
    echo "A tracked deletion did not change the digest." >&2
    exit 65
}

printf 'tracked-v1\n' > tracked.txt
[[ "$(digest)" == "$BASELINE" ]] || {
    echo "Restoring the source snapshot did not restore its digest." >&2
    exit 65
}

chmod 755 tracked.txt
[[ "$(digest)" != "$BASELINE" ]] || {
    echo "An executable-bit change did not change the digest." >&2
    exit 65
}
chmod 644 tracked.txt
[[ "$(digest)" == "$BASELINE" ]] || {
    echo "Restoring file mode did not restore the digest." >&2
    exit 65
}

echo "Source snapshot digest regression passed: $BASELINE"
