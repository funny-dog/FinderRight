#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/finderright-dmg-test.XXXXXX")"
MOUNT_POINT="$WORK_DIR/volume"
MOUNTED=0
cleanup() {
  if [ "$MOUNTED" = "1" ]; then
    hdiutil detach "$MOUNT_POINT" >/dev/null || return 1
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir "$WORK_DIR/source with spaces" "$MOUNT_POINT"
echo "FinderRight 图标回归检查" > "$WORK_DIR/source with spaces/readme.txt"
ln -s /Applications "$WORK_DIR/source with spaces/Applications"
ICON="$PROJECT_DIR/FinderRight/Resources/AppIcon.icns"

if bash "$PROJECT_DIR/scripts/package-dmg.sh" "$WORK_DIR/source with spaces" "$WORK_DIR/missing.icns" "$WORK_DIR/invalid.dmg" 2>/dev/null; then
  echo "错误：缺失图标时打包应失败" >&2
  exit 1
fi
[ ! -e "$WORK_DIR/invalid.dmg" ]
bash "$PROJECT_DIR/scripts/package-dmg.sh" "$WORK_DIR/source with spaces" "$ICON" "$WORK_DIR/original.dmg"

# 只复制文件数据，模拟 HTTP 下载不携带文件系统扩展属性。
dd if="$WORK_DIR/original.dmg" of="$WORK_DIR/downloaded.dmg" bs=1048576 2>/dev/null
[ -z "$(xattr "$WORK_DIR/downloaded.dmg")" ]
hdiutil verify "$WORK_DIR/downloaded.dmg" >/dev/null
MOUNTED=1
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_POINT" "$WORK_DIR/downloaded.dmg" >/dev/null
cmp "$ICON" "$MOUNT_POINT/.VolumeIcon.icns"
[ "$(xcrun GetFileInfo -aC "$MOUNT_POINT")" = "1" ]
cmp "$WORK_DIR/source with spaces/readme.txt" "$MOUNT_POINT/readme.txt"
[ "$(readlink "$MOUNT_POINT/Applications")" = "/Applications" ]
hdiutil detach "$MOUNT_POINT" >/dev/null
MOUNTED=0
echo "✓ DMG 下载副本保留卷图标、文件内容与 Applications 链接"
