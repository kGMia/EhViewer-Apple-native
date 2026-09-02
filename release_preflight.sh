#!/usr/bin/env zsh
# Release preflight for macOS, iOS and iPadOS. It performs metadata checks and
# unsigned Release static analysis builds; it does not archive, sign or upload.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_FILE="$SCRIPT_DIR/ehviewer apple.xcodeproj"
SCHEME="ehviewer apple"
APP_DIR="$SCRIPT_DIR/ehviewer apple"
DERIVED_DATA="$(mktemp -d /tmp/EhViewerApplePreflight.XXXXXX)"
trap 'rm -rf "$DERIVED_DATA"' EXIT

fail() {
    print -u2 "[失败] $1"
    exit 1
}

required_files=(
    "$SCRIPT_DIR/LICENSE"
    "$SCRIPT_DIR/README.md"
    "$SCRIPT_DIR/CHANGELOG.md"
    "$APP_DIR/Info.plist"
    "$APP_DIR/PrivacyInfo.xcprivacy"
    "$APP_DIR/ehviewer_apple.entitlements"
    "$APP_DIR/AppIcon.icon/icon.json"
    "$APP_DIR/zh-Hans.lproj/Localizable.strings"
    "$APP_DIR/zh-Hant.lproj/Localizable.strings"
    "$APP_DIR/en.lproj/Localizable.strings"
    "$SCRIPT_DIR/ehviewer apple Live Activity/Info.plist"
    "$SCRIPT_DIR/ehviewer apple Live Activity/DownloadLiveActivityWidget.swift"
)

for file in "${required_files[@]}"; do
    [[ -f "$file" ]] || fail "缺少发行文件：$file"
done

plutil -lint "$APP_DIR/Info.plist" >/dev/null
plutil -lint "$APP_DIR/PrivacyInfo.xcprivacy" >/dev/null
plutil -lint "$APP_DIR/ehviewer_apple.entitlements" >/dev/null
plutil -lint "$APP_DIR/zh-Hans.lproj/Localizable.strings" >/dev/null
plutil -lint "$APP_DIR/zh-Hant.lproj/Localizable.strings" >/dev/null
plutil -lint "$APP_DIR/en.lproj/Localizable.strings" >/dev/null
plutil -lint "$SCRIPT_DIR/ehviewer apple Live Activity/Info.plist" >/dev/null

[[ "$(plutil -extract ITSAppUsesNonExemptEncryption raw "$APP_DIR/Info.plist")" == "false" ]] \
    || fail "Info.plist 缺少免豁加密声明"

[[ "$(plutil -extract 'com\.apple\.security\.app-sandbox' raw "$APP_DIR/ehviewer_apple.entitlements")" == "true" ]] \
    || fail "macOS 发行权限未启用 App Sandbox"

marketing_versions="$(grep -Eo 'MARKETING_VERSION = [^;]+' "$PROJECT_FILE/project.pbxproj" | sed 's/.*= //' | sort -u)"
[[ "$(print -r -- "$marketing_versions" | wc -l | tr -d ' ')" == "1" ]] \
    || fail "主 App、扩展或测试目标的 MARKETING_VERSION 不一致"
release_version="$(print -r -- "$marketing_versions" | head -n 1)"
grep -Fq "version-${release_version}-" "$SCRIPT_DIR/README.md" \
    || fail "README 版本徽章与工程版本 $release_version 不一致"
grep -Fq "## [$release_version]" "$SCRIPT_DIR/CHANGELOG.md" \
    || fail "CHANGELOG 缺少版本 $release_version 的发行记录"
grep -Fq 'felixchaos/EhViewer-Apple' "$SCRIPT_DIR/README.md" \
    || fail "README 缺少上游项目署名"

if grep -REn 'Stellatrix|stellatrix\.icu|HWZEUNLCY6' \
    "$SCRIPT_DIR/.github" "$SCRIPT_DIR/README.md" "$SCRIPT_DIR/distribute_mac.sh" >/dev/null; then
    fail "公开发行文件中仍包含旧的私人部署标识"
fi

if grep -En 'NSAllowsArbitraryLoads' "$APP_DIR/Info.plist" >/dev/null; then
    fail "发行版不应启用全局 ATS 例外"
fi

grep -q 'INFOPLIST_KEY_NSSupportsLiveActivities = YES' "$PROJECT_FILE/project.pbxproj" \
    || fail "主 App 未声明 Live Activities 支持"

if grep -REn '<<<<<<<|=======|>>>>>>>' "$APP_DIR" "$SCRIPT_DIR/Packages" >/dev/null; then
    fail "源码中仍有 Git 冲突标记"
fi

if [[ "${1:-}" == "--metadata-only" ]]; then
    print "[通过] 发行元数据、隐私声明与 Live Activity 配置检查完成"
    exit 0
fi

print "[检查] macOS Release 静态分析…"
env DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
    xcodebuild -quiet analyze \
    -project "$PROJECT_FILE" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO

print "[检查] iOS/iPadOS Release 静态分析…"
env DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
    xcodebuild -quiet analyze \
    -project "$PROJECT_FILE" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "generic/platform=iOS Simulator" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO

print "[通过] 发行元数据、隐私声明与双平台静态分析完成"
