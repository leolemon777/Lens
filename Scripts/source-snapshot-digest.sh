#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${1:-$(pwd)}"

if [[ ! -d "$PROJECT_DIR/.git" ]]; then
    echo "Not a Git worktree: $PROJECT_DIR" >&2
    exit 66
fi

cd "$PROJECT_DIR"

# Hash exactly the source-visible snapshot: every tracked file plus every
# untracked, non-ignored file. Build outputs, local media and other ignored
# artifacts are intentionally excluded. NUL delimiters preserve arbitrary
# legal filenames and LC_ALL=C fixes byte ordering across locales.
git ls-files --cached --others --exclude-standard -z \
    | LC_ALL=C sort -z \
    | while IFS= read -r -d '' path; do
        if [[ -L "$path" ]]; then
            link_sha="$(readlink -- "$path" | shasum -a 256 | awk '{print $1}')"
            printf 'symlink\0%s\0%s\0' "$path" "$link_sha"
        elif [[ -f "$path" ]]; then
            file_sha="$(shasum -a 256 -- "$path" | awk '{print $1}')"
            file_mode="$(stat -f '%Lp' -- "$path")"
            printf 'file\0%s\0%s\0%s\0' "$path" "$file_mode" "$file_sha"
        else
            # A deleted tracked path is part of a valid dirty development
            # snapshot. Represent the tombstone instead of silently omitting it.
            printf 'deleted\0%s\0' "$path"
        fi
    done \
    | shasum -a 256 \
    | awk '{print $1}'
