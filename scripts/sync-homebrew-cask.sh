#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

fail() {
  echo "错误：$*" >&2
  exit 1
}

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PROJECT_DIR/FinderRight/Info.plist")"
fi
VERSION="${VERSION#v}"

SHA256="${2:-}"
if [ -z "$SHA256" ]; then
  if [ -f "$PROJECT_DIR/FinderRight-v${VERSION}.zip.sha256" ]; then
    SHA256="$(awk '{print $1}' "$PROJECT_DIR/FinderRight-v${VERSION}.zip.sha256")"
  elif [ -f "$PROJECT_DIR/website/dist/download/v$VERSION/FinderRight-v${VERSION}.zip.sha256" ]; then
    SHA256="$(awk '{print $1}' "$PROJECT_DIR/website/dist/download/v$VERSION/FinderRight-v${VERSION}.zip.sha256")"
  elif [ -f "$PROJECT_DIR/FinderRight-v${VERSION}.zip" ]; then
    SHA256="$(shasum -a 256 "$PROJECT_DIR/FinderRight-v${VERSION}.zip" | awk '{print $1}')"
  elif command -v gh >/dev/null 2>&1; then
    SHA256="$(gh release view "v$VERSION" --json assets -q ".assets[] | select(.name == \"FinderRight-v${VERSION}.zip\") | .digest" 2>/dev/null || true)"
    SHA256="${SHA256#sha256:}"
  fi
fi

[ -n "$SHA256" ] || fail "未找到 FinderRight-v${VERSION}.zip 的 SHA-256 校验和"
[[ "$SHA256" =~ ^[0-9a-fA-F]{64}$ ]] || fail "非法的 SHA-256: $SHA256"

# 定位 Tap 仓库
TAP_DIR="$(brew --repository funny-dog/tap 2>/dev/null || true)"
if [ -z "$TAP_DIR" ] || [ ! -d "$TAP_DIR" ]; then
  TAP_DIR="/opt/homebrew/Library/Taps/funny-dog/homebrew-tap"
fi
[ -d "$TAP_DIR" ] || fail "找不到 Homebrew Tap 目录：$TAP_DIR"

CASK_FILE="$TAP_DIR/Casks/finderright.rb"
[ -f "$CASK_FILE" ] || fail "找不到 Cask 文件：$CASK_FILE"

echo "=== 同步 Homebrew Cask ==="
echo "Tap 路径: $TAP_DIR"
echo "版本: $VERSION"
echo "ZIP SHA-256: $SHA256"

# 确保 tap 处于最新 main
git -C "$TAP_DIR" fetch --quiet origin main
git -C "$TAP_DIR" pull --ff-only origin main

# 更新 Cask 文件
python3 - "$CASK_FILE" "$VERSION" "$SHA256" <<'PY'
import sys, re
from pathlib import Path

path = Path(sys.argv[1])
version = sys.argv[2]
sha256 = sys.argv[3]

content = path.read_text()
new_content, n_v = re.subn(r'^  version "[^"]+"$', f'  version "{version}"', content, flags=re.M)
assert n_v == 1, "未找到或无法唯一匹配 version 字段"

new_content, n_s = re.subn(r'^  sha256 "[^"]+"$', f'  sha256 "{sha256}"', new_content, flags=re.M)
assert n_s == 1, "未找到或无法唯一匹配 sha256 字段"

path.write_text(new_content)
print(f"已更新 {path} 为版本 {version}")
PY

# 运行校验
echo "校验 Cask style..."
HOMEBREW_NO_AUTO_UPDATE=1 brew style --cask funny-dog/tap/finderright
echo "校验 Cask audit..."
HOMEBREW_NO_AUTO_UPDATE=1 brew audit --cask funny-dog/tap/finderright
echo "校验 Cask fetch..."
HOMEBREW_NO_AUTO_UPDATE=1 brew fetch --cask funny-dog/tap/finderright

# 提交并推送 Tap
if [ -n "$(git -C "$TAP_DIR" status --porcelain)" ]; then
  git -C "$TAP_DIR" add Casks/finderright.rb
  git -C "$TAP_DIR" commit -m "chore: 更新 FinderRight 到 $VERSION"
  git -C "$TAP_DIR" push origin main
  echo "Tap 提交已推送到 origin/main"
else
  echo "Cask 内容未发生改变，跳过提交"
fi

# 若存在独立的开发 checkout，同步更新
USER_TAP_DIR="$HOME/codes/practice/homebrew-tap"
if [ -d "$USER_TAP_DIR" ] && [ "$USER_TAP_DIR" != "$TAP_DIR" ]; then
  git -C "$USER_TAP_DIR" pull --ff-only origin main 2>/dev/null || true
  echo "本地 checkout $USER_TAP_DIR 已同步"
fi

echo "Homebrew Cask 同步完成：funny-dog/tap/finderright (v$VERSION)"
