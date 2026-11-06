#!/usr/bin/env bash
set -euo pipefail

# 获取工程根目录
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

# 由 SwiftPM 给出实际产物目录：不同版本的工具链布局不同（.build/out/Products/Release 或 .build/release）
KIT_BUILD_DIR="$(swift build -c release --disable-sandbox --package-path FinderRightKit --show-bin-path)"

echo "=== [CI] 1. 编译 FinderRightKit (Release) ==="
swift build -c release --disable-sandbox --package-path FinderRightKit

swiftc -parse-as-library -target arm64-apple-macos13.0 \
  -I "$KIT_BUILD_DIR" -I "$KIT_BUILD_DIR/Modules" \
  -L "$KIT_BUILD_DIR" -lFinderRightKit \
  scripts/test-service-drift.swift -o "$KIT_BUILD_DIR/test-service-drift"
"$KIT_BUILD_DIR/test-service-drift"

echo "=== [CI] 2. 运行 FinderRightKit 单元测试 ==="
swift run --disable-sandbox --package-path FinderRightKit FinderRightKitTests

KIT_TEST_BINARY="$(swift build --disable-sandbox --package-path FinderRightKit --show-bin-path)/FinderRightKitTests" python3 - <<'PY'
import os
import subprocess

for word in ("__finderright_no_matching_test__", "   "):
    result = subprocess.run(
        [os.environ["KIT_TEST_BINARY"]],
        env={**os.environ, "FINDERRIGHT_TEST_FILTER": word},
        text=True, capture_output=True,
    )
    assert result.returncode == 1 and "总数 0" in result.stdout, (
        f"过滤词 {word!r} 应因未匹配测试而失败：{result.returncode}\n{result.stdout}\n{result.stderr}"
    )
print("PASS: 无匹配与空白过滤词均拒绝空跑")
PY

swiftc -parse-as-library -target arm64-apple-macos13.0 \
  -I "$KIT_BUILD_DIR" -I "$KIT_BUILD_DIR/Modules" \
  -L "$KIT_BUILD_DIR" -lFinderRightKit \
  scripts/test-cut-queue-removal.swift -o "$KIT_BUILD_DIR/test-cut-queue-removal"
"$KIT_BUILD_DIR/test-cut-queue-removal"

echo "=== [CI] 3. 静态类型检查主程序 FinderRight ==="
swiftc -parse-as-library -target arm64-apple-macos13.0 \
  -I "$KIT_BUILD_DIR" -I "$KIT_BUILD_DIR/Modules" \
  -L "$KIT_BUILD_DIR" -lFinderRightKit \
  FinderRight/AppDelegate+Termination.swift FinderRight/Services/ApplicationTermination.swift \
  scripts/test-app-termination.swift \
  -o "$KIT_BUILD_DIR/test-app-termination"
"$KIT_BUILD_DIR/test-app-termination"

swiftc -parse-as-library -target arm64-apple-macos13.0 \
  FinderRight/Views/SettingsPresentation.swift scripts/test-settings-presentation.swift \
  -o "$KIT_BUILD_DIR/test-settings-presentation"
"$KIT_BUILD_DIR/test-settings-presentation"

swiftc -parse-as-library -target arm64-apple-macos13.0 \
  -I "$KIT_BUILD_DIR" -I "$KIT_BUILD_DIR/Modules" \
  -L "$KIT_BUILD_DIR" -lFinderRightKit \
  FinderRight/FRState.swift FinderRight/Views/Components/Theme.swift \
  FinderRight/Views/Components/FRDialog.swift scripts/test-clipboard-file-dialog.swift \
  -o "$KIT_BUILD_DIR/test-clipboard-file-dialog"
"$KIT_BUILD_DIR/test-clipboard-file-dialog"

swiftc -parse-as-library -target arm64-apple-macos13.0 \
  -I "$KIT_BUILD_DIR" -I "$KIT_BUILD_DIR/Modules" \
  -L "$KIT_BUILD_DIR" -lFinderRightKit \
  FinderRight/Views/FavoriteDirectoryStatus.swift scripts/test-favorite-directory-status.swift \
  -o "$KIT_BUILD_DIR/test-favorite-directory-status"
"$KIT_BUILD_DIR/test-favorite-directory-status"

swiftc -parse-as-library -target arm64-apple-macos13.0 \
  FinderRight/Services/LaunchPresentation.swift scripts/test-launch-presentation.swift \
  -o "$KIT_BUILD_DIR/test-launch-presentation"
"$KIT_BUILD_DIR/test-launch-presentation"

swiftc -parse-as-library -target arm64-apple-macos13.0 \
  -I "$KIT_BUILD_DIR" -I "$KIT_BUILD_DIR/Modules" \
  -L "$KIT_BUILD_DIR" -lFinderRightKit \
  FinderRight/Services/LaunchPresentation.swift \
  FinderRight/Services/ApplicationTermination.swift \
  FinderRight/Services/UpdateChecker.swift FinderRight/Services/UpdateInstallReceipt.swift \
  scripts/test-automatic-updates.swift -o "$KIT_BUILD_DIR/test-automatic-updates"
"$KIT_BUILD_DIR/test-automatic-updates"

swiftc -parse-as-library -target arm64-apple-macos13.0 \
  -I "$KIT_BUILD_DIR" -I "$KIT_BUILD_DIR/Modules" \
  -L "$KIT_BUILD_DIR" -lFinderRightKit \
  FinderRight/Services/LaunchPresentation.swift \
  FinderRight/Services/ApplicationTermination.swift \
  FinderRight/Services/UpdateChecker.swift FinderRight/Services/UpdateInstallReceipt.swift \
  scripts/test-update-relaunch.swift -o "$KIT_BUILD_DIR/test-update-relaunch"
"$KIT_BUILD_DIR/test-update-relaunch"

swiftc -parse-as-library -target arm64-apple-macos13.0 \
  -I "$KIT_BUILD_DIR" -I "$KIT_BUILD_DIR/Modules" \
  -L "$KIT_BUILD_DIR" -lFinderRightKit \
  FinderRight/Services/FinderRightService+Image.swift scripts/test-image-service.swift \
  -o "$KIT_BUILD_DIR/test-image-service"
"$KIT_BUILD_DIR/test-image-service"

swiftc -parse-as-library -target arm64-apple-macos13.0 \
  -I "$KIT_BUILD_DIR" -I "$KIT_BUILD_DIR/Modules" \
  -L "$KIT_BUILD_DIR" -lFinderRightKit \
  FinderRight/FRState.swift FinderRight/Views/Components/Theme.swift \
  FinderRight/Views/Components/FRDialog.swift FinderRight/Views/OperationHistoryView.swift FinderRight/Views/OperationHistoryRow.swift \
  scripts/test-operation-history.swift -o "$KIT_BUILD_DIR/test-operation-history"
"$KIT_BUILD_DIR/test-operation-history"

swiftc -typecheck -parse-as-library \
  -target arm64-apple-macos13.0 \
  -I "$KIT_BUILD_DIR" -I "$KIT_BUILD_DIR/Modules" \
  FinderRight/*.swift \
  FinderRight/Services/*.swift \
  FinderRight/Views/*.swift \
  FinderRight/Views/Components/*.swift

# 上面这步在有完整 Xcode 的机器上总能过，但仓库承诺「只需 Command Line Tools」。
# libSwiftUIMacros.dylib 只在 Xcode 的 Platform 目录下，CLT 里没有，实测只有
# @State 与 @Bindable 依赖它（@StateObject/@ObservedObject/@Published/@AppStorage/
# @FocusState/@Binding 等都正常），报错形如
# "external macro implementation type ... could not be found"。
# 本机与 GitHub Actions 都带完整 Xcode，这类回归只会在别人的机器上炸，所以按源码拦一道。
# 先去注释再匹配，避免把「注释里提到 @State」误判成真的使用了它。
if grep -rnE '@(State|Bindable)\b' --include=*.swift \
     FinderRight FinderRightSync FinderRightPreview FinderRightMarkdown FinderRightKit/Sources \
     | sed -E 's@(^|[^:])//.*$@\1@' \
     | grep -E '@(State|Bindable)\b'; then
  echo "错误：上面这些属性包装器依赖 SwiftUIMacros，纯 Command Line Tools 下不可用。" >&2
  echo "      @State 请改用 @FRState（见 FinderRight/FRState.swift）。" >&2
  exit 1
fi

# 使用真实热键注册与事件派发，但仅写临时配置，不启动窗口或更改用户快捷键。
APP_TEST_SOURCES=()
for source in FinderRight/*.swift; do
  if [ "$source" != "FinderRight/FinderRightApp.swift" ]; then
    APP_TEST_SOURCES+=("$source")
  fi
done
swiftc -parse-as-library -target arm64-apple-macos13.0 \
  -I "$KIT_BUILD_DIR" -I "$KIT_BUILD_DIR/Modules" \
  -L "$KIT_BUILD_DIR" -lFinderRightKit \
  "${APP_TEST_SOURCES[@]}" FinderRight/Services/*.swift \
  FinderRight/Views/*.swift FinderRight/Views/Components/*.swift \
  scripts/test-global-directory-shortcut.swift -o "$KIT_BUILD_DIR/test-global-directory-shortcut"
"$KIT_BUILD_DIR/test-global-directory-shortcut"

swiftc -parse-as-library \
  -target arm64-apple-macos13.0 \
  -I "$KIT_BUILD_DIR" -I "$KIT_BUILD_DIR/Modules" \
  -L "$KIT_BUILD_DIR" -lFinderRightKit \
  FinderRight/Services/PreviewExtensionManager.swift scripts/test-preview-settings.swift \
  -o "$KIT_BUILD_DIR/test-preview-settings"
"$KIT_BUILD_DIR/test-preview-settings"

echo "=== [CI] 4. 静态类型检查扩展 FinderRightSync ==="
swiftc -parse-as-library -target arm64-apple-macos13.0 \
  -I "$KIT_BUILD_DIR" -I "$KIT_BUILD_DIR/Modules" \
  -L "$KIT_BUILD_DIR" -lFinderRightKit \
  -framework FinderSync -framework AppKit \
  FinderRightSync/*.swift scripts/test-monitored-volumes.swift \
  -o "$KIT_BUILD_DIR/test-monitored-volumes"
"$KIT_BUILD_DIR/test-monitored-volumes"

swiftc -parse-as-library -target arm64-apple-macos13.0 \
  FinderRightSync/SingleOptionMenu.swift scripts/test-single-option-menu.swift \
  -o "$KIT_BUILD_DIR/test-single-option-menu"
"$KIT_BUILD_DIR/test-single-option-menu"

swiftc -typecheck -parse-as-library \
  -target arm64-apple-macos13.0 \
  -I "$KIT_BUILD_DIR" -I "$KIT_BUILD_DIR/Modules" \
  -framework FinderSync -framework AppKit \
  FinderRightSync/*.swift

swiftc -parse-as-library -target arm64-apple-macos13.0 \
  -I "$KIT_BUILD_DIR" -I "$KIT_BUILD_DIR/Modules" \
  -L "$KIT_BUILD_DIR" -lFinderRightKit \
  FinderRightSync/MenuIconRenderer.swift scripts/test-menu-icons.swift \
  -o "$KIT_BUILD_DIR/test-menu-icons"
"$KIT_BUILD_DIR/test-menu-icons"

swiftc -parse-as-library -target arm64-apple-macos13.0 \
  -I "$KIT_BUILD_DIR" -I "$KIT_BUILD_DIR/Modules" \
  -L "$KIT_BUILD_DIR" -lFinderRightKit \
  scripts/test-syntax-highlight.swift -o "$KIT_BUILD_DIR/test-syntax-highlight"
"$KIT_BUILD_DIR/test-syntax-highlight"

echo "=== [CI] 5. 编译 Quick Look 扩展代码并运行预览集成检查 ==="
for check in documents archives zip request; do
  swiftc -parse-as-library -target arm64-apple-macos13.0 \
    -I "$KIT_BUILD_DIR" -I "$KIT_BUILD_DIR/Modules" \
    -L "$KIT_BUILD_DIR" -lFinderRightKit \
    "scripts/test-preview-$check.swift" -o "$KIT_BUILD_DIR/test-preview-$check"
  "$KIT_BUILD_DIR/test-preview-$check"
done
swiftc -parse-as-library \
  -module-name FinderRightPreview \
  -target arm64-apple-macos13.0 \
  -I "$KIT_BUILD_DIR" -I "$KIT_BUILD_DIR/Modules" \
  -L "$KIT_BUILD_DIR" -lFinderRightKit \
  -framework QuickLookUI -framework AppKit \
  FinderRightPreview/*.swift scripts/test-preview.swift \
  -o "$KIT_BUILD_DIR/test-preview"
"$KIT_BUILD_DIR/test-preview"
swiftc -parse-as-library \
  -module-name FinderRightMarkdown \
  -target arm64-apple-macos13.0 \
  -I "$KIT_BUILD_DIR" -I "$KIT_BUILD_DIR/Modules" \
  -L "$KIT_BUILD_DIR" -lFinderRightKit \
  -framework QuickLookUI -framework AppKit \
  FinderRightMarkdown/*.swift FinderRightPreview/DocumentPreviewView.swift scripts/test-markdown-preview.swift \
  -o "$KIT_BUILD_DIR/test-markdown-preview"
"$KIT_BUILD_DIR/test-markdown-preview"

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

echo "=== [CI] 7. 校验官网下载、页面与更新代理 ==="
python3 website/check.py
# node 不属于 macOS 自带，也不随 Command Line Tools 提供。只在改了官网 Worker 时才会用到，
# 缺它不该让「编 App」这件事失败；装了就跑，没装就跳过并提示。
if command -v node >/dev/null 2>&1; then
  node --check website/worker/index.js
  node website/worker/test.mjs
else
  echo "跳过：未安装 node，跳过官网 Worker 的 JS 校验（不影响 App 构建）"
fi
bash scripts/test-website-downloads.sh
bash scripts/test-release.sh

echo ""
echo "========================================="
echo "  ✓ 本地 CI 全部检查通过 (ALL GREEN)！"
echo "========================================="
