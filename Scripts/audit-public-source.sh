#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MAX_TRACKED_BYTES=$((5 * 1024 * 1024))
FAILURES=0

cd "$PROJECT_DIR"

fail() {
    echo "public-source audit: $1" >&2
    FAILURES=$((FAILURES + 1))
}

required_files=(
    "README.md"
    "PRIVACY.md"
    "SECURITY.md"
    "CONTRIBUTING.md"
    "docs/第三方依赖与素材清单.md"
    "docs/发布检查清单.md"
    ".github/ISSUE_TEMPLATE/bug_report.yml"
    ".github/ISSUE_TEMPLATE/feature_request.yml"
    ".github/PULL_REQUEST_TEMPLATE.md"
)

for path in "${required_files[@]}"; do
    if [[ ! -f "$path" ]]; then
        fail "missing required public file: $path"
    fi
done

if [[ -e ".gitmodules" ]]; then
    fail "git submodules require an explicit license and source audit"
fi

if git ls-files -s | awk '$1 == "120000" { found = 1 } END { exit !found }'; then
    fail "tracked symbolic links are not allowed without an explicit audit"
fi

shopt -s nocasematch
while IFS= read -r -d '' path; do
    case "$path" in
        Build/*|.build/*|DerivedData/*|*.xcuserstate|xcuserdata/*)
            fail "tracked build or user artifact: $path"
            ;;
        *.screentrace|*.mp4|*.mov|*.mkv|*.avi|*.caf|*.m4a|*.mp3|*.wav|*.heic|*.ips|*.crash)
            fail "tracked private media, project, or crash artifact: $path"
            ;;
        *.dmg|*.pkg|*.zip|*.tar|*.gz|*.7z|*.app|*.framework|*.xcframework)
            fail "tracked binary or release artifact: $path"
            ;;
        *.p12|*.pfx|*.pem|*.key|*.cer|*.der|*.mobileprovision|*.provisionprofile|.env|.env.*)
            fail "tracked credential or signing artifact: $path"
            ;;
    esac

    size="$(stat -f '%z' "$path")"
    if (( size > MAX_TRACKED_BYTES )); then
        fail "tracked file exceeds 5 MiB: $path ($size bytes)"
    fi

    mime_type="$(file -b --mime-type "$path")"
    case "$mime_type" in
        text/*|application/json|application/xml|application/x-empty|application/x-shellscript|inode/x-empty)
            ;;
        *)
            fail "tracked non-text file requires an explicit asset review: $path ($mime_type)"
            ;;
    esac
done < <(git ls-files -z)
shopt -u nocasematch

secret_pattern='-----BEGIN ([A-Z0-9]+ )?PRIVATE KEY-----|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{30,}|sk-[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{20,}'
set +e
matches="$(git grep -nE -e "$secret_pattern" -- . ':!Scripts/audit-public-source.sh')"
secret_scan_status=$?
set -e
if (( secret_scan_status == 0 )); then
    fail "possible credential material found:\n$matches"
elif (( secret_scan_status != 1 )); then
    fail "credential scan could not complete (git grep status $secret_scan_status)"
fi

tracked_count="$(git ls-files | wc -l | tr -d ' ')"
if (( FAILURES > 0 )); then
    echo "Public-source audit failed with $FAILURES issue(s)." >&2
    exit 1
fi

echo "Public-source audit passed for $tracked_count tracked text files."
if [[ ! -f "LICENSE" ]]; then
    echo "Release remains blocked: choose a license and add LICENSE."
fi
