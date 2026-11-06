#!/usr/bin/env bash
set -euo pipefail

# 把 build/ 里的本地构建装到 /Applications 并启动，供直接使用和验收。
#
# 为什么不直接 `open build/dmg-stage/FinderRight.app`：
# staging 产物与已安装副本的 bundle id 完全相同，打开它会让 PluginKit 登记出第二条同 id 的
# FinderSync 扩展，Finder 右键菜单随即整段出现两套。这里改成「覆盖安装到同一路径」，
# 保证任何时候都只有一份登记，并在安装后校验扩展注册数量。

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

SOURCE_APP="$PROJECT_DIR/build/dmg-stage/FinderRight.app"
TARGET_APP="/Applications/FinderRight.app"
BUNDLE_ID="com.finderright.app"
EXTENSION_ID="com.finderright.app.sync"

if [ ! -d "$SOURCE_APP" ]; then
  echo "错误：找不到 $SOURCE_APP，请先运行 bash scripts/build.sh" >&2
  exit 1
fi

echo "=== 1. 校验构建产物签名 ==="
codesign --verify --strict "$SOURCE_APP"
# 自签名证书的 Authority 行不一定出现在精简输出里，取不到时不打印，避免显示空值
authority="$(codesign -dvv "$SOURCE_APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
if [ -n "$authority" ]; then
  echo "签名有效：$authority"
else
  echo "签名有效"
fi

echo "=== 2. 退出正在运行的 FinderRight ==="
pkill -f "$TARGET_APP/Contents/MacOS/FinderRight" 2>/dev/null || true
sleep 1

echo "=== 3. 覆盖安装到 $TARGET_APP ==="
rm -rf "$TARGET_APP"
cp -R "$SOURCE_APP" "$TARGET_APP"
codesign --verify --strict "$TARGET_APP"

echo "=== 4. 清理 staging 产物的插件登记 ==="
# staging 里的扩展若曾被打开过，会在插件登记表里留下同 id 的第二条记录，导致菜单出现两套
pluginkit -r "$SOURCE_APP/Contents/PlugIns/FinderRightSync.appex" >/dev/null 2>&1 || true

echo "=== 5. 启动 ==="
open "$TARGET_APP"
sleep 2

echo "=== 6. 校验扩展只剩一份登记 ==="
registered="$(pluginkit -m -D -p com.apple.FinderSync 2>/dev/null | grep -c "$EXTENSION_ID" || true)"
echo "扩展登记数量：$registered"
if [ "$registered" -ne 1 ]; then
  echo "警告：$EXTENSION_ID 登记了 $registered 份，右键菜单可能重复显示。" >&2
  echo "      常见原因是从 build/ 或备份目录直接打开过 App。可执行：pluginkit -r <多余的那个.appex>" >&2
  exit 1
fi

echo ""
echo "=== 安装完成 ==="
echo "版本：$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TARGET_APP/Contents/Info.plist")（构建号 $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$TARGET_APP/Contents/Info.plist")）"
echo "位置：$TARGET_APP"
