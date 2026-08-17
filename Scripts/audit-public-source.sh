#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MAX_TRACKED_BYTES=$((5 * 1024 * 1024))
APP_ICON_PATH="Assets/AppIcon.png"
APP_ICON_SHA256="92588341cd37aef36689b86e4bd6e41f19b8acca6533fb945fbf2b41e91e443d"
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
    "$APP_ICON_PATH"
    "docs/第三方依赖与素材清单.md"
    "docs/品牌资产说明.md"
    "docs/发布检查清单.md"
    "docs/发布撤回与回滚手册.md"
    "docs/templates/发布状态说明模板.md"
    "docs/templates/安全公告模板.md"
    "Scripts/verify-macos-release.sh"
    "Scripts/source-snapshot-digest.sh"
    "Scripts/test-source-snapshot-digest.sh"
    "Scripts/run-g4-accessibility-audit.sh"
    "Scripts/g4-accessibility-audit.swift"
    "Scripts/generate-release-notes.sh"
    "Scripts/archive-macos-release.sh"
    "Scripts/verify-macos-release-archive.sh"
    ".github/ISSUE_TEMPLATE/bug_report.yml"
    ".github/ISSUE_TEMPLATE/feature_request.yml"
    ".github/PULL_REQUEST_TEMPLATE.md"
)

for path in "${required_files[@]}"; do
    if [[ ! -f "$path" ]]; then
        fail "missing required public file: $path"
    fi
done

required_template_sections=(
    "docs/templates/发布状态说明模板.md|## 当前状态"
    "docs/templates/发布状态说明模板.md|## 用户数据与权限"
    "docs/templates/发布状态说明模板.md|## 当前缓解措施"
    "docs/templates/发布状态说明模板.md|## 修复与验证"
    "docs/templates/发布状态说明模板.md|## 获取帮助与安全报告"
    "docs/templates/发布状态说明模板.md|## 发布前检查"
    "docs/templates/安全公告模板.md|## 公告身份"
    "docs/templates/安全公告模板.md|## 受影响范围"
    "docs/templates/安全公告模板.md|## 数据与权限影响"
    "docs/templates/安全公告模板.md|## 临时缓解措施"
    "docs/templates/安全公告模板.md|## 修复与验证"
    "docs/templates/安全公告模板.md|## 时间线"
    "docs/templates/安全公告模板.md|## 发布前检查"
)
for requirement in "${required_template_sections[@]}"; do
    IFS='|' read -r path heading <<< "$requirement"
    if [[ -f "$path" ]] && ! grep -Fqx -- "$heading" "$path"; then
        fail "required response template section is missing: $path: $heading"
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
        image/png)
            if [[ "$path" != "$APP_ICON_PATH" ]]; then
                fail "tracked image is not an explicitly audited brand asset: $path"
            fi
            ;;
        *)
            fail "tracked non-text file requires an explicit asset review: $path ($mime_type)"
            ;;
    esac
done < <(git ls-files -z)
shopt -u nocasematch

if [[ -f "$APP_ICON_PATH" ]]; then
    app_icon_sha256="$(shasum -a 256 "$APP_ICON_PATH" | awk '{print $1}')"
    app_icon_width="$(sips -g pixelWidth "$APP_ICON_PATH" | awk '/pixelWidth/ { print $2 }')"
    app_icon_height="$(sips -g pixelHeight "$APP_ICON_PATH" | awk '/pixelHeight/ { print $2 }')"
    app_icon_alpha="$(sips -g hasAlpha "$APP_ICON_PATH" | awk '/hasAlpha/ { print $2 }')"
    if [[ "$app_icon_sha256" != "$APP_ICON_SHA256" ]]; then
        fail "app icon changed without an explicit asset review: $APP_ICON_PATH"
    fi
    if [[ "$app_icon_width" != "1024" || "$app_icon_height" != "1024" ]]; then
        fail "app icon master must be 1024x1024: $APP_ICON_PATH"
    fi
    if [[ "$app_icon_alpha" != "no" ]]; then
        fail "app icon master must be an opaque RGB image: $APP_ICON_PATH"
    fi
fi

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

echo "Public-source audit passed for $tracked_count tracked public files."
if [[ ! -f "LICENSE" ]]; then
    echo "Release remains blocked: choose a license and add LICENSE."
fi
