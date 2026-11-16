#!/usr/bin/env bash
set -euo pipefail

# 获取工程根目录
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

# 由 SwiftPM 给出实际产物目录：不同版本的工具链布局不同（.build/out/Products/Release 或 .build/release）
KIT_BUILD_DIR="$(swift build -c release --disable-sandbox --package-path FinderRightKit --show-bin-path)"
export KIT_BUILD_DIR PROJECT_DIR

echo "=== [CI] 1. 编译 FinderRightKit (Release) ==="
swift build -c release --disable-sandbox --package-path FinderRightKit

echo "=== [CI] 2. 并发运行单元测试、静态检查、扩展校验与回归脚本 ==="
python3 - <<'PY'
from concurrent.futures import ThreadPoolExecutor, as_completed
import os
from pathlib import Path
import subprocess
import sys
import time

kit = os.environ["KIT_BUILD_DIR"]
root = Path(os.environ["PROJECT_DIR"])
app_test_sources = " ".join(
    str(p) for p in sorted(Path("FinderRight").glob("*.swift")) if p.name != "FinderRightApp.swift"
)

def build_and_run(name: str, cmd: str) -> tuple[str, str]:
    return (name, cmd)

TASKS = [
    build_and_run("FinderRightKit 单元测试与过滤校验", f"""set -euo pipefail
swift run --disable-sandbox --package-path FinderRightKit FinderRightKitTests
KIT_TEST_BINARY="$(swift build --disable-sandbox --package-path FinderRightKit --show-bin-path)/FinderRightKitTests" python3 - <<'INNER'
import os, subprocess
for word in ("__finderright_no_matching_test__", "   "):
    result = subprocess.run([os.environ["KIT_TEST_BINARY"]], env={{**os.environ, "FINDERRIGHT_TEST_FILTER": word}}, text=True, capture_output=True)
    assert result.returncode == 1 and "总数 0" in result.stdout, f"过滤词 {{word!r}} 应因未匹配测试而失败：{{result.returncode}}\\n{{result.stdout}}\\n{{result.stderr}}"
print("PASS: 无匹配与空白过滤词均拒绝空跑")
INNER"""),
    build_and_run("服务菜单防漂移检查", f'swiftc -parse-as-library -target arm64-apple-macos13.0 -I "{kit}" -I "{kit}/Modules" -L "{kit}" -lFinderRightKit scripts/test-service-drift.swift -o "{kit}/test-service-drift" && "{kit}/test-service-drift"'),
    build_and_run("开发者菜单检查", f'swiftc -parse-as-library -target arm64-apple-macos13.0 -I "{kit}" -I "{kit}/Modules" -L "{kit}" -lFinderRightKit scripts/test-developer-menu.swift -o "{kit}/test-developer-menu" && "{kit}/test-developer-menu"'),
    build_and_run("剪切队列单项移除检查", f'swiftc -parse-as-library -target arm64-apple-macos13.0 -I "{kit}" -I "{kit}/Modules" -L "{kit}" -lFinderRightKit scripts/test-cut-queue-removal.swift -o "{kit}/test-cut-queue-removal" && "{kit}/test-cut-queue-removal"'),
    build_and_run("Git 状态检查", f'swiftc -parse-as-library -target arm64-apple-macos13.0 -I "{kit}" -I "{kit}/Modules" -L "{kit}" -lFinderRightKit scripts/test-git-status.swift -o "{kit}/test-git-status" && "{kit}/test-git-status"'),
    build_and_run("Git 本地操作检查", f'swiftc -parse-as-library -target arm64-apple-macos13.0 -I "{kit}" -I "{kit}/Modules" -L "{kit}" -lFinderRightKit scripts/test-git-operations.swift -o "{kit}/test-git-operations" && "{kit}/test-git-operations"'),
    build_and_run("Git 远程拉取推送检查", f'swiftc -parse-as-library -target arm64-apple-macos13.0 -I "{kit}" -I "{kit}/Modules" -L "{kit}" -lFinderRightKit scripts/test-git-pull-push.swift -o "{kit}/test-git-pull-push" && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all FINDERRIGHT_GIT_ALLOW_PROTOCOL=file "{kit}/test-git-pull-push"'),
    build_and_run("临时窗口激活策略检查", f'swiftc -parse-as-library -target arm64-apple-macos13.0 FinderRight/Views/TransientWindowManager.swift scripts/test-transient-windows.swift -o "{kit}/test-transient-windows" && "{kit}/test-transient-windows"'),
    build_and_run("应用退出与后台等待检查", f'swiftc -parse-as-library -target arm64-apple-macos13.0 -I "{kit}" -I "{kit}/Modules" -L "{kit}" -lFinderRightKit FinderRight/AppDelegate+Termination.swift FinderRight/Services/ApplicationTermination.swift scripts/test-app-termination.swift -o "{kit}/test-app-termination" && "{kit}/test-app-termination"'),
    build_and_run("设置窗口展示检查", f'swiftc -parse-as-library -target arm64-apple-macos13.0 FinderRight/Views/SettingsPresentation.swift scripts/test-settings-presentation.swift -o "{kit}/test-settings-presentation" && "{kit}/test-settings-presentation"'),
    build_and_run("文件比较视图检查", f'swiftc -parse-as-library -target arm64-apple-macos13.0 -I "{kit}" -I "{kit}/Modules" -L "{kit}" -lFinderRightKit FinderRight/FRState.swift FinderRight/Views/Components/Theme.swift FinderRight/Views/TransientWindowManager.swift FinderRight/Views/FileComparisonView.swift scripts/test-file-comparison-view.swift -o "{kit}/test-file-comparison-view" && "{kit}/test-file-comparison-view"'),
    build_and_run("Git 状态视图检查", f'swiftc -parse-as-library -target arm64-apple-macos13.0 -I "{kit}" -I "{kit}/Modules" -L "{kit}" -lFinderRightKit FinderRight/FRState.swift FinderRight/Views/Components/Theme.swift FinderRight/Views/TransientWindowManager.swift FinderRight/Views/FileComparisonView.swift FinderRight/Views/GitStatusView.swift scripts/test-git-status-view.swift -o "{kit}/test-git-status-view" && "{kit}/test-git-status-view"'),
    build_and_run("剪贴板新建弹窗检查", f'swiftc -parse-as-library -target arm64-apple-macos13.0 -I "{kit}" -I "{kit}/Modules" -L "{kit}" -lFinderRightKit FinderRight/FRState.swift FinderRight/Views/Components/Theme.swift FinderRight/Views/Components/FRDialog.swift scripts/test-clipboard-file-dialog.swift -o "{kit}/test-clipboard-file-dialog" && "{kit}/test-clipboard-file-dialog"'),
    build_and_run("常用目录状态检查", f'swiftc -parse-as-library -target arm64-apple-macos13.0 -I "{kit}" -I "{kit}/Modules" -L "{kit}" -lFinderRightKit FinderRight/Views/FavoriteDirectoryStatus.swift scripts/test-favorite-directory-status.swift -o "{kit}/test-favorite-directory-status" && "{kit}/test-favorite-directory-status"'),
    build_and_run("启动展示策略检查", f'swiftc -parse-as-library -target arm64-apple-macos13.0 FinderRight/Services/LaunchPresentation.swift scripts/test-launch-presentation.swift -o "{kit}/test-launch-presentation" && "{kit}/test-launch-presentation"'),
    build_and_run("自动更新策略检查", f'swiftc -parse-as-library -target arm64-apple-macos13.0 -I "{kit}" -I "{kit}/Modules" -L "{kit}" -lFinderRightKit FinderRight/Services/LaunchPresentation.swift FinderRight/Services/ApplicationTermination.swift FinderRight/Services/UpdateChecker.swift FinderRight/Services/UpdateInstallReceipt.swift scripts/test-automatic-updates.swift -o "{kit}/test-automatic-updates" && "{kit}/test-automatic-updates"'),
    build_and_run("更新替换脚本检查", f'swiftc -parse-as-library -target arm64-apple-macos13.0 -I "{kit}" -I "{kit}/Modules" -L "{kit}" -lFinderRightKit FinderRight/Services/LaunchPresentation.swift FinderRight/Services/ApplicationTermination.swift FinderRight/Services/UpdateChecker.swift FinderRight/Services/UpdateInstallReceipt.swift scripts/test-update-relaunch.swift -o "{kit}/test-update-relaunch" && "{kit}/test-update-relaunch"'),
    build_and_run("图片服务检查", f'swiftc -parse-as-library -target arm64-apple-macos13.0 -I "{kit}" -I "{kit}/Modules" -L "{kit}" -lFinderRightKit FinderRight/Services/FinderRightService+Image.swift scripts/test-image-service.swift -o "{kit}/test-image-service" && "{kit}/test-image-service"'),
    build_and_run("操作历史界面检查", f'swiftc -parse-as-library -target arm64-apple-macos13.0 -I "{kit}" -I "{kit}/Modules" -L "{kit}" -lFinderRightKit FinderRight/FRState.swift FinderRight/Views/Components/Theme.swift FinderRight/Views/Components/FRDialog.swift FinderRight/Views/OperationHistoryView.swift FinderRight/Views/OperationHistoryRow.swift scripts/test-operation-history.swift -o "{kit}/test-operation-history" && "{kit}/test-operation-history"'),
    build_and_run("主程序 FinderRight 类型检查", f'swiftc -typecheck -parse-as-library -target arm64-apple-macos13.0 -I "{kit}" -I "{kit}/Modules" FinderRight/*.swift FinderRight/Services/*.swift FinderRight/Views/*.swift FinderRight/Views/Components/*.swift'),
    build_and_run("无 Xcode 宏禁用检查 (@State/@Bindable)", """set -euo pipefail
if grep -rnE '@(State|Bindable)\\b' --include=*.swift FinderRight FinderRightSync FinderRightPreview FinderRightMarkdown FinderRightKit/Sources | sed -E 's@(^|[^:])//.*$@\\1@' | grep -E '@(State|Bindable)\\b'; then
  echo "错误：以上属性包装器依赖 SwiftUIMacros，纯 Command Line Tools 下不可用。@State 请改用 @FRState。" >&2
  exit 1
fi"""),
    build_and_run("预编译全局快捷键集成测试", f'swiftc -parse-as-library -target arm64-apple-macos13.0 -I "{kit}" -I "{kit}/Modules" -L "{kit}" -lFinderRightKit {app_test_sources} FinderRight/Services/*.swift FinderRight/Views/*.swift FinderRight/Views/Components/*.swift scripts/test-global-directory-shortcut.swift -o "{kit}/test-global-directory-shortcut"'),
    build_and_run("预编译预览开关集成测试", f'swiftc -parse-as-library -target arm64-apple-macos13.0 -I "{kit}" -I "{kit}/Modules" -L "{kit}" -lFinderRightKit FinderRight/Services/PreviewExtensionManager.swift scripts/test-preview-settings.swift -o "{kit}/test-preview-settings"'),
    build_and_run("FinderSync 挂载卷与类型检查", f'swiftc -parse-as-library -target arm64-apple-macos13.0 -I "{kit}" -I "{kit}/Modules" -L "{kit}" -lFinderRightKit -framework FinderSync -framework AppKit FinderRightSync/*.swift scripts/test-monitored-volumes.swift -o "{kit}/test-monitored-volumes" && "{kit}/test-monitored-volumes" && swiftc -typecheck -parse-as-library -target arm64-apple-macos13.0 -I "{kit}" -I "{kit}/Modules" -framework FinderSync -framework AppKit FinderRightSync/*.swift'),
    build_and_run("单选菜单检查", f'swiftc -parse-as-library -target arm64-apple-macos13.0 FinderRightSync/SingleOptionMenu.swift scripts/test-single-option-menu.swift -o "{kit}/test-single-option-menu" && "{kit}/test-single-option-menu"'),
    build_and_run("菜单图标渲染检查", f'swiftc -parse-as-library -target arm64-apple-macos13.0 -I "{kit}" -I "{kit}/Modules" -L "{kit}" -lFinderRightKit FinderRightSync/MenuIconRenderer.swift scripts/test-menu-icons.swift -o "{kit}/test-menu-icons" && "{kit}/test-menu-icons"'),
    build_and_run("代码高亮检查", f'swiftc -parse-as-library -target arm64-apple-macos13.0 -I "{kit}" -I "{kit}/Modules" -L "{kit}" -lFinderRightKit scripts/test-syntax-highlight.swift -o "{kit}/test-syntax-highlight" && "{kit}/test-syntax-highlight"'),
    build_and_run("QuickLook 预览子项检查", f"""set -euo pipefail
for check in documents archives zip request; do
  swiftc -parse-as-library -target arm64-apple-macos13.0 -I "{kit}" -I "{kit}/Modules" -L "{kit}" -lFinderRightKit "scripts/test-preview-$check.swift" -o "{kit}/test-preview-$check"
  "{kit}/test-preview-$check"
done"""),
    build_and_run("QuickLook 扩展集成检查", f'swiftc -parse-as-library -module-name FinderRightPreview -target arm64-apple-macos13.0 -I "{kit}" -I "{kit}/Modules" -L "{kit}" -lFinderRightKit -framework QuickLookUI -framework AppKit FinderRightPreview/*.swift scripts/test-preview.swift -o "{kit}/test-preview" && "{kit}/test-preview"'),
    build_and_run("Markdown 扩展集成检查", f'swiftc -parse-as-library -module-name FinderRightMarkdown -target arm64-apple-macos13.0 -I "{kit}" -I "{kit}/Modules" -L "{kit}" -lFinderRightKit -framework QuickLookUI -framework AppKit FinderRightMarkdown/*.swift FinderRightPreview/DocumentPreviewView.swift scripts/test-markdown-preview.swift -o "{kit}/test-markdown-preview" && "{kit}/test-markdown-preview"'),
    build_and_run("官网资产、镜像同步与发布脚本回归", """set -euo pipefail
python3 website/check.py
if command -v node >/dev/null 2>&1; then
  node --check website/worker/index.js
  node website/worker/test.mjs
else
  echo "跳过：未安装 node，跳过官网 Worker 的 JS 校验（不影响 App 构建）"
fi
bash scripts/test-website-downloads.sh
bash scripts/test-release.sh"""),
]

def run_task(item: tuple[str, str]):
    name, cmd = item
    start = time.monotonic()
    res = subprocess.run(["/bin/bash", "-c", cmd], cwd=root, text=True, capture_output=True)
    return name, res.returncode, res.stdout, res.stderr, time.monotonic() - start

workers = min(6, os.cpu_count() or 4)
failed = []
with ThreadPoolExecutor(max_workers=workers) as pool:
    futures = [pool.submit(run_task, t) for t in TASKS]
    for fut in as_completed(futures):
        name, rc, out, err, elapsed = fut.result()
        status = "✓" if rc == 0 else "✗"
        print(f"  {status} {name} ({elapsed:.1f}s)", flush=True)
        if rc != 0:
            failed.append((name, rc, out, err))

if failed:
    for name, rc, out, err in failed:
        print(f"\n=== [失败] {name} (exit={rc}) ===", file=sys.stderr)
        if out:
            print(out, file=sys.stderr)
        if err:
            print(err, file=sys.stderr)
    sys.exit(1)
PY

echo "=== [CI] 3. 运行系统环境相关检查（全局热键 / QuickLook 开关）==="
"$KIT_BUILD_DIR/test-global-directory-shortcut"
"$KIT_BUILD_DIR/test-preview-settings"

echo "=== [CI] 4. 校验中英文案覆盖率 ==="
# 面向用户的文案都写在 Swift 里、以中文原文作 key 查 en.lproj。漏翻译不会导致编译或运行失败，
# 只会在英文系统上悄悄退回中文，所以单独兜一道。带插值的文案在表里是 %@ 占位，跳过比对。
python3 - <<'PY'
import re
import sys
from pathlib import Path

def read_keys(path: Path) -> set[str]:
    keys = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        match = re.match(r'^"((?:[^"\\]|\\.)*)"\s*=', line)
        if match:
            keys.add(match.group(1))
    return keys

def has_chinese(text: str) -> bool:
    return bool(re.search(r'[\u4e00-\u9fff]', text)) and "\\(" not in text

root = Path("FinderRight")
app_keys = read_keys(root / "en.lproj" / "Localizable.strings")
sync_keys = read_keys(Path("FinderRightSync/en.lproj/Localizable.strings"))

# 语言名在中英文界面里都显示原文，不需要翻译
allow = {"中文"}

pattern = re.compile(
    r'(?:Text|NSLocalizedString|Button|Label|FRCaption|LocalizedStringKey)\(\s*"((?:[^"\\]|\\.)*)"'
    r'|FRPage\(title:\s*"((?:[^"\\]|\\.)*)"'
    r'|\bL\(\s*"((?:[^"\\]|\\.)*)"'
    r'|\.help\(\s*"((?:[^"\\]|\\.)*)"'
)
app_literals = set()
for path in sorted(root.rglob("*.swift")):
    for match in pattern.finditer(path.read_text(encoding="utf-8")):
        text = next(group for group in match.groups() if group is not None)
        if has_chinese(text):
            app_literals.add(text)

# Kit 中面向主 App 界面的更新日志、功能清单与预设名称
kit = Path("FinderRightKit/Sources/FinderRightKit")
for p in (
    kit / "ChangelogCatalog.swift",
    kit / "FileContentReader.swift",
    kit / "CopyPathFormat.swift",
    kit / "Theme.swift",
    kit / "OperationHistoryPresentation.swift",
    kit / "OfficeTemplate.swift",
):
    for m in re.finditer(r'(?:textKey:\s*|return\s+)"((?:[^"\\]|\\.)*)"', p.read_text(encoding="utf-8")):
        if has_chinese(m.group(1)):
            app_literals.add(m.group(1))

mf_text = (kit / "MenuFeature.swift").read_text(encoding="utf-8")
for m in re.finditer(r'(?:nameKey|descriptionKey):\s*"((?:[^"\\]|\\.)*)"', mf_text):
    if has_chinese(m.group(1)):
        app_literals.add(m.group(1))

# 扩展侧需要本地化的菜单文案与提示
sync_literals = set()
for p in sorted(Path("FinderRightSync").glob("*.swift")):
    for m in re.finditer(r'(?:\bL|NSLocalizedString)\(\s*"((?:[^"\\]|\\.)*)"', p.read_text(encoding="utf-8")):
        if has_chinese(m.group(1)):
            sync_literals.add(m.group(1))
for m in re.finditer(r'nameKey:\s*"((?:[^"\\]|\\.)*)"', mf_text):
    if has_chinese(m.group(1)):
        sync_literals.add(m.group(1))
for m in re.finditer(r'titleKey:\s*"((?:[^"\\]|\\.)*)"', (kit / "MenuModel.swift").read_text(encoding="utf-8")):
    if has_chinese(m.group(1)):
        sync_literals.add(m.group(1))
for m in re.finditer(r'NewFileTemplateItem\([^)]*name:\s*"((?:[^"\\]|\\.)*)"', (kit / "NewFileTemplateCatalog.swift").read_text(encoding="utf-8")):
    if has_chinese(m.group(1)):
        sync_literals.add(m.group(1))
for m in re.finditer(r'localize\(\s*"((?:[^"\\]|\\.)*)"', (kit / "FilePermissions.swift").read_text(encoding="utf-8")):
    if has_chinese(m.group(1)):
        sync_literals.add(m.group(1))

missing_app = sorted(app_literals - app_keys - allow)
missing_sync = sorted(sync_literals - sync_keys - allow)
print(f"主 App 文案 {len(app_literals)} 条（英文表 {len(app_keys)} 条，缺失 {len(missing_app)} 条）；"
      f"扩展文案 {len(sync_literals)} 条（英文表 {len(sync_keys)} 条，缺失 {len(missing_sync)} 条）")
for text in missing_app:
    print(f"  - [主 App] 缺少英文翻译：{text}")
for text in missing_sync:
    print(f"  - [FinderSync] 缺少英文翻译：{text}")
sys.exit(1 if (missing_app or missing_sync) else 0)
PY

echo ""
echo "========================================="
echo "  ✓ 本地 CI 全部检查通过 (ALL GREEN)！"
echo "========================================="
