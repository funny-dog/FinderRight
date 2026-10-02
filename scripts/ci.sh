#!/usr/bin/env bash
set -euo pipefail

# 获取工程根目录
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

# 由 SwiftPM 给出实际产物目录：不同版本的工具链布局不同（.build/out/Products/Release 或 .build/release）
KIT_BUILD_DIR="$(swift build -c release --package-path FinderRightKit --show-bin-path)"

echo "=== [CI] 1. 编译 FinderRightKit (Release) ==="
swift build -c release --package-path FinderRightKit

echo "=== [CI] 2. 运行 FinderRightKit 单元测试 ==="
swift run --package-path FinderRightKit FinderRightKitTests

echo "=== [CI] 3. 静态类型检查主程序 FinderRight ==="
swiftc -typecheck -parse-as-library \
  -target arm64-apple-macos13.0 \
  -I "$KIT_BUILD_DIR" -I "$KIT_BUILD_DIR/Modules" \
  FinderRight/*.swift \
  FinderRight/Services/*.swift \
  FinderRight/Views/*.swift \
  FinderRight/Views/Components/*.swift

echo "=== [CI] 4. 静态类型检查扩展 FinderRightSync ==="
swiftc -typecheck -parse-as-library \
  -target arm64-apple-macos13.0 \
  -I "$KIT_BUILD_DIR" -I "$KIT_BUILD_DIR/Modules" \
  -framework FinderSync -framework AppKit \
  FinderRightSync/*.swift

echo ""
echo "========================================="
echo "  ✓ 本地 CI 全部检查通过 (ALL GREEN)！"
echo "========================================="
