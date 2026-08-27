#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <release.json> <SHA256SUMS.txt>" >&2
    exit 64
fi

MANIFEST_PATH="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
CHECKSUMS_PATH="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
MANIFEST_DIR="$(dirname "$MANIFEST_PATH")"

[[ -f "$MANIFEST_PATH" ]] || { echo "Missing release manifest: $MANIFEST_PATH" >&2; exit 66; }
[[ -f "$CHECKSUMS_PATH" ]] || { echo "Missing checksum list: $CHECKSUMS_PATH" >&2; exit 66; }
[[ "$(dirname "$CHECKSUMS_PATH")" == "$MANIFEST_DIR" ]] \
    || { echo "Manifest and checksums must share one release directory." >&2; exit 65; }

manifest_value() {
    plutil -extract "$1" raw "$MANIFEST_PATH"
}

PRODUCT="$(manifest_value product)"
APP_VERSION="$(manifest_value version)"
BUILD_NUMBER="$(manifest_value buildNumber)"
RELEASE_CHANNEL="$(manifest_value releaseChannel)"
BUNDLE_IDENTIFIER="$(manifest_value bundleIdentifier)"
MINIMUM_MACOS="$(manifest_value minimumMacOS)"
GIT_COMMIT="$(manifest_value git.commit)"
MACHO_UUID="$(manifest_value binary.machOUUID)"
SIGNING_KIND="$(manifest_value signing.kind)"
APP_NOTARY_STATUS="$(manifest_value notarization.app.status)"
DMG_NOTARY_STATUS="$(manifest_value notarization.dmg.status)"
ARTIFACT_NAME="$PRODUCT-$APP_VERSION-$BUILD_NUMBER"
OUTPUT_PATH="$MANIFEST_DIR/$ARTIFACT_NAME-RELEASE_NOTES.md"
TEMP_PATH="$(mktemp "$MANIFEST_DIR/.release-notes.XXXXXX")"

cleanup() {
    rm -f "$TEMP_PATH"
}
trap cleanup EXIT

[[ "$PRODUCT" == "Lens" ]] || { echo "Unexpected product: $PRODUCT" >&2; exit 65; }
[[ "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] \
    || { echo "Invalid version: $APP_VERSION" >&2; exit 65; }
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo "Invalid build number: $BUILD_NUMBER" >&2; exit 65; }
case "$RELEASE_CHANNEL" in
    alpha) CHANNEL_LABEL="Alpha" ;;
    beta) CHANNEL_LABEL="Beta" ;;
    stable) CHANNEL_LABEL="Stable" ;;
    *) echo "Invalid release channel: $RELEASE_CHANNEL" >&2; exit 65 ;;
esac

EXPECTED_FILES=(
    "$ARTIFACT_NAME.dmg"
    "$ARTIFACT_NAME.app.zip"
    "$ARTIFACT_NAME.dSYM.zip"
    "$ARTIFACT_NAME-release.json"
)

checksum_count=0
while read -r checksum filename trailing; do
    [[ "$checksum" =~ ^[0-9a-f]{64}$ && -n "$filename" && -z "${trailing:-}" ]] \
        || { echo "Malformed checksum entry in $CHECKSUMS_PATH" >&2; exit 65; }
    expected=0
    for expected_file in "${EXPECTED_FILES[@]}"; do
        if [[ "$filename" == "$expected_file" ]]; then
            expected=1
            break
        fi
    done
    [[ "$expected" -eq 1 ]] || { echo "Unexpected checksum file: $filename" >&2; exit 65; }
    checksum_count=$((checksum_count + 1))
done < "$CHECKSUMS_PATH"
[[ "$checksum_count" -eq 4 ]] \
    || { echo "Expected four checksum entries before generating release notes." >&2; exit 65; }
for expected_file in "${EXPECTED_FILES[@]}"; do
    [[ "$(awk -v file="$expected_file" '$2 == file { count++ } END { print count + 0 }' "$CHECKSUMS_PATH")" -eq 1 ]] \
        || { echo "Checksum entry missing or duplicated: $expected_file" >&2; exit 65; }
done

if [[ "$SIGNING_KIND" == "developer-id" \
    && "$APP_NOTARY_STATUS" == "Accepted" \
    && "$DMG_NOTARY_STATUS" == "Accepted" ]]; then
    DISTRIBUTION_STATUS="公开分发候选：Developer ID 签名及 App/DMG 公证已记录；仍须以公开模式校验器最终确认。"
else
    DISTRIBUTION_STATUS="开发验收候选：当前签名为 ${SIGNING_KIND}，App/DMG 公证状态为 ${APP_NOTARY_STATUS}/${DMG_NOTARY_STATUS}，不可作为公开下载包。"
fi

{
    printf '# Lens %s (%s) · %s\n\n' "$APP_VERSION" "$BUILD_NUMBER" "$CHANNEL_LABEL"
    printf '本文件由发布脚本根据不可变制品清单生成。\n\n'
    printf '## 发布身份\n\n'
    printf -- '- 发布级别: %s\n' "$RELEASE_CHANNEL"
    printf -- '- Bundle ID: %s\n' "$BUNDLE_IDENTIFIER"
    printf -- '- 最低系统: macOS %s 或更高\n' "$MINIMUM_MACOS"
    printf -- '- Git commit: %s\n' "$GIT_COMMIT"
    printf -- '- Mach-O UUID: %s\n' "$MACHO_UUID"
    printf -- '- 分发状态: %s\n\n' "$DISTRIBUTION_STATUS"
    printf '## 本版能力\n\n'
    printf -- '- 区域、窗口、多窗口、当前显示器截图，以及滚动长截图、OCR、标注、贴图和 PNG/JPEG 导出。\n'
    printf -- '- 区域、窗口、显示器录屏，独立系统声/麦克风/摄像头轨，暂停继续、中断恢复和开放项目包。\n'
    printf -- '- 自动运镜、平滑光标、点击效果、字幕、设备端转写、本地整理、视频标注、画中画和三档导出。\n'
    printf -- '- 默认本地处理，不包含帐号、分析埋点、广告 SDK、云上传或自动更新客户端。\n\n'
    printf '## 权限与数据\n\n'
    printf -- '- 截图和录屏需要“屏幕与系统音频录制”；可选讲解、人像和设备端转写分别需要麦克风、摄像头和语音识别权限。\n'
    printf -- '- 项目默认位于 `~/Pictures/Lens/`；升级或卸载 App 不应删除该目录。\n'
    printf -- '- `.lens` 是开放项目包；0.1 录屏/截图黄金样本和旧偏好键已通过向后兼容测试。\n\n'
    printf '## 已知限制\n\n'
    printf -- '- 物理 Fn 键盘矩阵、多显示器混合缩放、浏览器/普通 App 长截图矩阵、1 小时录制、设备拔出和 VoiceOver 仍需专项真机验收。\n'
    printf -- '- 当前版本不包含生成式云模型、语义聚类、批量整理或自动更新。\n'
    printf -- '- 未经 Developer ID 签名、公证、Staple 与 Gatekeeper 公开校验的候选包仅限开发验收。\n\n'
    printf '## SHA-256\n\n```text\n'
    cat "$CHECKSUMS_PATH"
    printf '```\n'
} > "$TEMP_PATH"

mv "$TEMP_PATH" "$OUTPUT_PATH"
trap - EXIT
echo "$OUTPUT_PATH"
