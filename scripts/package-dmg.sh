#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "用法：package-dmg.sh <源目录> <卷图标.icns> <输出.dmg>" >&2
  exit 2
fi
[ -d "$1" ] || { echo "错误：找不到源目录 $1" >&2; exit 1; }
[ -s "$2" ] || { echo "错误：找不到卷图标 $2" >&2; exit 1; }

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/finderright-dmg.XXXXXX")"
MOUNT_POINT="$WORK_DIR/volume"
MOUNTED=0
cleanup() {
  if [ "$MOUNTED" = "1" ]; then
    if ! hdiutil detach "$MOUNT_POINT" >/dev/null; then
      echo "错误：临时卷未能卸载，保留 $WORK_DIR，请手动卸载后清理" >&2
      return 1
    fi
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

hdiutil create -volname "FinderRight" -srcfolder "$1" -fs HFS+ -format UDRW "$WORK_DIR/writable.dmg" >/dev/null
mkdir "$MOUNT_POINT"
MOUNTED=1
hdiutil attach -nobrowse -mountpoint "$MOUNT_POINT" "$WORK_DIR/writable.dmg" >/dev/null

# 图标与卷标记都写进镜像内部，普通 HTTP 下载也能保留挂载后的磁盘图标。
cp "$2" "$MOUNT_POINT/.VolumeIcon.icns"
xcrun SetFile -a C "$MOUNT_POINT"
hdiutil detach "$MOUNT_POINT" >/dev/null
MOUNTED=0
hdiutil convert "$WORK_DIR/writable.dmg" -format UDZO -ov -o "$3" >/dev/null
