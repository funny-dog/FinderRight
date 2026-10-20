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
swiftc -parse-as-library -target arm64-apple-macos13.0 \
  FinderRight/Services/LaunchPresentation.swift scripts/test-launch-presentation.swift \
  -o "$KIT_BUILD_DIR/test-launch-presentation"
"$KIT_BUILD_DIR/test-launch-presentation"

swiftc -typecheck -parse-as-library \
  -target arm64-apple-macos13.0 \
  -I "$KIT_BUILD_DIR" -I "$KIT_BUILD_DIR/Modules" \
  FinderRight/*.swift \
  FinderRight/Services/*.swift \
  FinderRight/Views/*.swift \
  FinderRight/Views/Components/*.swift

swiftc -parse-as-library \
  -target arm64-apple-macos13.0 \
  -I "$KIT_BUILD_DIR" -I "$KIT_BUILD_DIR/Modules" \
  -L "$KIT_BUILD_DIR" -lFinderRightKit \
  FinderRight/Services/PreviewExtensionManager.swift scripts/test-preview-settings.swift \
  -o "$KIT_BUILD_DIR/test-preview-settings"
"$KIT_BUILD_DIR/test-preview-settings"

echo "=== [CI] 4. 静态类型检查扩展 FinderRightSync ==="
swiftc -parse-as-library -target arm64-apple-macos13.0 \
  FinderRightSync/SingleOptionMenu.swift scripts/test-single-option-menu.swift \
  -o "$KIT_BUILD_DIR/test-single-option-menu"
"$KIT_BUILD_DIR/test-single-option-menu"

swiftc -typecheck -parse-as-library \
  -target arm64-apple-macos13.0 \
  -I "$KIT_BUILD_DIR" -I "$KIT_BUILD_DIR/Modules" \
  -framework FinderSync -framework AppKit \
  FinderRightSync/*.swift

echo "=== [CI] 5. 编译 Quick Look 扩展代码并运行预览集成检查 ==="
swiftc -parse-as-library \
  -module-name FinderRightPreview \
  -target arm64-apple-macos13.0 \
  -I "$KIT_BUILD_DIR" -I "$KIT_BUILD_DIR/Modules" \
  -L "$KIT_BUILD_DIR" -lFinderRightKit \
  -framework QuickLookUI -framework AppKit \
  FinderRightPreview/*.swift scripts/test-preview.swift \
  -o "$KIT_BUILD_DIR/test-preview"
"$KIT_BUILD_DIR/test-preview"

echo "=== [CI] 6. 校验中英文案覆盖率 ==="
# 面向用户的文案都写在 Swift 里、以中文原文作 key 查 en.lproj。漏翻译不会导致编译或运行失败，
# 只会在英文系统上悄悄退回中文，所以单独兜一道。带插值的文案在表里是 %@ 占位，跳过比对。
python3 - <<'PY'
import re
import sys
from pathlib import Path

root = Path("FinderRight")
table = root / "en.lproj" / "Localizable.strings"
keys = set()
for line in table.read_text(encoding="utf-8").splitlines():
    match = re.match(r'^"((?:[^"\\]|\\.)*)"\s*=', line)
    if match:
        keys.add(match.group(1))

# 语言名在中英文界面里都显示原文，不需要翻译
allow = {"中文"}

pattern = re.compile(
    r'(?:Text|NSLocalizedString|Button|Label|FRCaption)\(\s*"((?:[^"\\]|\\.)*)"'
    r'|FRPage\(title:\s*"((?:[^"\\]|\\.)*)"'
    r'|\bL\(\s*"((?:[^"\\]|\\.)*)"'
)
literals = set()
for path in sorted(root.rglob("*.swift")):
    for match in pattern.finditer(path.read_text(encoding="utf-8")):
        text = next(group for group in match.groups() if group is not None)
        if not re.search(r'[\u4e00-\u9fff]', text) or "\\(" in text:
            continue
        literals.add(text)

missing = sorted(literals - keys - allow)
print(f"中文字面量 {len(literals)} 条，英文表 {len(keys)} 条，缺失 {len(missing)} 条")
for text in missing:
    print(f"  - 缺少英文翻译：{text}")
sys.exit(1 if missing else 0)
PY

echo ""
echo "========================================="
echo "  ✓ 本地 CI 全部检查通过 (ALL GREEN)！"
echo "========================================="
