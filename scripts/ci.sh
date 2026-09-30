#!/usr/bin/env bash
set -euo pipefail

# 获取工程根目录
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

KIT_BUILD_DIR="$PROJECT_DIR/FinderRightKit/.build/out/Products/Release"

echo "=== [CI] 1. 编译 FinderRightKit (Release) ==="
swift build -c release --package-path FinderRightKit

echo "=== [CI] 2. 运行 FinderRightKit 单元测试 ==="
swift run --package-path FinderRightKit FinderRightKitTests

echo "=== [CI] 3. 静态类型检查主程序 FinderRight ==="
swiftc -typecheck -parse-as-library \
  -target arm64-apple-macos13.0 \
  -I "$KIT_BUILD_DIR" \
  FinderRight/*.swift \
  FinderRight/Services/*.swift \
  FinderRight/Views/*.swift \
  FinderRight/Views/Components/*.swift

echo "=== [CI] 4. 静态类型检查扩展 FinderRightSync ==="
swiftc -typecheck -parse-as-library \
  -target arm64-apple-macos13.0 \
  -I "$KIT_BUILD_DIR" \
  -framework FinderSync -framework AppKit \
  FinderRightSync/*.swift

echo ""
echo "========================================="
echo "  ✓ 本地 CI 全部检查通过 (ALL GREEN)！"
echo "========================================="
