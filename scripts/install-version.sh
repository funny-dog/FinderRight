#!/usr/bin/env bash
set -euo pipefail

# 把本机 FinderRight 覆盖安装为指定的已发布版本（从 GitHub Release 下载）。
# 用法：bash scripts/install-version.sh [x.y.z]
# 不带参数时，安装当前已安装版本的上一个正式版本。

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

INSTALLED_PLIST="/Applications/FinderRight.app/Contents/Info.plist"
version="${1:-}"
version="${version#v}"

if [ -z "$version" ]; then
  [ -f "$INSTALLED_PLIST" ] || { echo "错误：未安装 FinderRight，请指定版本号" >&2; exit 1; }
  current="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INSTALLED_PLIST")"
  version="$(gh release list --exclude-drafts --exclude-pre-releases -L 100 --json tagName -q '.[].tagName' \
    | sed 's/^v//' | sort -t. -k1,1nr -k2,2nr -k3,3nr \
    | awk -v cur="$current" 'found { print; exit } $0 == cur { found = 1 }')"
  [ -n "$version" ] || { echo "错误：找不到 $current 的上一个版本" >&2; exit 1; }
  echo "当前版本 ${current}，目标上一个版本 ${version}"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "=== 下载 v$version ==="
gh release download "v$version" --pattern "FinderRight-v$version.zip*" --dir "$tmp"
(cd "$tmp" && shasum -a 256 -c "FinderRight-v$version.zip.sha256")
ditto -x -k "$tmp/FinderRight-v$version.zip" "$tmp/out"

SOURCE_APP="$tmp/out/FinderRight.app" bash scripts/install-local.sh
