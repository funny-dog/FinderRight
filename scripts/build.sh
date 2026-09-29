#!/usr/bin/env bash
set -euo pipefail

# 注意：当前构建目标指定为 arm64-apple-macos13.0（仅支持 Apple Silicon 架构）。
# 未构建 Universal Binary（x86_64 + arm64），因此编译产物仅适用于 Apple Silicon (M 系列芯片) Mac，Intel Mac 无法直接运行。

# 根目录
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

VERSION="1.1.6"
STAGE_DIR="$PROJECT_DIR/build/dmg-stage"
APP_DIR="$STAGE_DIR/FinderRight.app"
APPEX_DIR="$APP_DIR/Contents/PlugIns/FinderRightSync.appex"
KIT_BUILD_DIR="$PROJECT_DIR/FinderRightKit/.build/out/Products/Release"

echo "=== 1. 编译 FinderRightKit (Release) ==="
swift build -c release --package-path FinderRightKit

# 清空 stage 目录：历史上 Assets.car 靠旧构建残留"碰巧"被带进 DMG，
# 掩盖了脚本从未编译 asset catalog 的问题（v1.1.5 干净构建后菜单栏图标消失）。
# 每次从干净目录组装，残留文件不再掩盖缺步骤。
rm -rf "$STAGE_DIR"

echo "=== 2. 编译主程序 FinderRight (Release) ==="
mkdir -p "$APP_DIR/Contents/MacOS"
swiftc -O -parse-as-library \
  -target arm64-apple-macos13.0 \
  -I "$KIT_BUILD_DIR" \
  -L "$KIT_BUILD_DIR" -lFinderRightKit \
  FinderRight/*.swift \
  FinderRight/Services/*.swift \
  FinderRight/Views/*.swift \
  FinderRight/Views/Components/*.swift \
  -o "$APP_DIR/Contents/MacOS/FinderRight"

echo "=== 3. 编译扩展 FinderRightSync (Release) ==="
mkdir -p "$APPEX_DIR/Contents/MacOS"
swiftc -O -parse-as-library \
  -target arm64-apple-macos13.0 \
  -I "$KIT_BUILD_DIR" \
  -L "$KIT_BUILD_DIR" -lFinderRightKit \
  -framework FinderSync -framework AppKit \
  -Xlinker -e -Xlinker _NSExtensionMain \
  FinderRightSync/*.swift \
  -o "$APPEX_DIR/Contents/MacOS/FinderRightSync"

echo "=== 4. 组装与替换 Plist 变量 ==="
# 主 App Info.plist
sed \
  -e 's/\$(DEVELOPMENT_LANGUAGE)/zh-Hans/g' \
  -e 's/\$(EXECUTABLE_NAME)/FinderRight/g' \
  -e 's/\$(PRODUCT_BUNDLE_IDENTIFIER)/com.finderright.app/g' \
  -e 's/\$(PRODUCT_NAME)/FinderRight/g' \
  FinderRight/Info.plist > "$APP_DIR/Contents/Info.plist"

echo -n "APPL????" > "$APP_DIR/Contents/PkgInfo"

# 主 App Resources (Localizable.strings & AppIcon)
mkdir -p "$APP_DIR/Contents/Resources/en.lproj"
cp FinderRight/en.lproj/Localizable.strings "$APP_DIR/Contents/Resources/en.lproj/"
if [ -f "FinderRight/Resources/AppIcon.icns" ]; then
  cp FinderRight/Resources/AppIcon.icns "$APP_DIR/Contents/Resources/"
fi

# 菜单栏图标 MenuBarIcon 只存在于 asset catalog 中，NSImage(named:) 必须在
# bundle 内找到同名资源，否则返回 nil → 状态栏项零宽不可见（v1.1.5 曾因此回归）。
# 优先用 actool 编译整个 xcassets（需完整 Xcode）；本仓库支持无 Xcode 构建，
# 无 actool 时退化为把 imageset 的 PNG 按 NSImage 命名约定（name.png / name@2x.png）
# 复制为散文件——NSImage(named:) 对散文件同样自动处理 @2x。
if xcrun -f actool >/dev/null 2>&1; then
  xcrun actool FinderRight/Assets.xcassets \
    --compile "$APP_DIR/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 13.0 \
    --errors --warnings
else
  MENU_ICON_SET="FinderRight/Assets.xcassets/MenuBarIcon.imageset"
  cp "$MENU_ICON_SET/menubar_16x16.png" "$APP_DIR/Contents/Resources/MenuBarIcon.png"
  cp "$MENU_ICON_SET/menubar_32x32.png" "$APP_DIR/Contents/Resources/MenuBarIcon@2x.png"
fi

# 硬校验：菜单栏图标必须进了 bundle，否则立即构建失败，不再静默回归
if [ ! -f "$APP_DIR/Contents/Resources/Assets.car" ] && [ ! -f "$APP_DIR/Contents/Resources/MenuBarIcon.png" ]; then
  echo "错误：菜单栏图标未打进 bundle（既无 Assets.car 也无 MenuBarIcon.png）" >&2
  exit 1
fi

# 扩展 Info.plist
sed \
  -e 's/\$(DEVELOPMENT_LANGUAGE)/zh-Hans/g' \
  -e 's/\$(EXECUTABLE_NAME)/FinderRightSync/g' \
  -e 's/\$(PRODUCT_BUNDLE_IDENTIFIER)/com.finderright.app.sync/g' \
  -e 's/\$(PRODUCT_NAME)/FinderRightSync/g' \
  -e 's/\$(PRODUCT_MODULE_NAME)/FinderRightSync/g' \
  FinderRightSync/Info.plist > "$APPEX_DIR/Contents/Info.plist"

echo -n "XPC!????" > "$APPEX_DIR/Contents/PkgInfo"
mkdir -p "$APPEX_DIR/Contents/Resources/en.lproj"
cp FinderRightSync/en.lproj/Localizable.strings "$APPEX_DIR/Contents/Resources/en.lproj/"

echo "=== 5. 代码签名 (Ad-hoc) ==="
# 注意：严禁在对主 App 签名时使用 --deep！
# --deep 会递归进入 PlugIns 目录，用主 App 的无沙箱配置覆盖抹除 FinderRightSync 的 app-sandbox 权限，
# 导致 PluginKit 判定扩展未开启沙箱而静默拒绝加载（pluginkit 输出 no matches，右键菜单彻底消失）。
# 正确方式：自内向外（Inside-Out）逐层独立签名：
codesign -s - --force --entitlements FinderRightSync/FinderRightSync.entitlements "$APPEX_DIR"
codesign -s - --force --entitlements FinderRight/FinderRight.entitlements "$APP_DIR"

echo "=== 6. 创建 Applications 软链接 ==="
ln -shf /Applications "$STAGE_DIR/Applications"

echo "=== 7. 打包 DMG 与 ZIP ==="
mkdir -p "$PROJECT_DIR/build"
rm -f "$PROJECT_DIR/build/FinderRight-$VERSION.dmg" "$PROJECT_DIR/FinderRight.dmg" "$PROJECT_DIR/FinderRight-v$VERSION.zip"

hdiutil create -volname "FinderRight" -srcfolder "$STAGE_DIR" -ov -format UDZO "$PROJECT_DIR/build/FinderRight-$VERSION.dmg"
cp "$PROJECT_DIR/build/FinderRight-$VERSION.dmg" "$PROJECT_DIR/FinderRight.dmg"

(cd "$STAGE_DIR" && zip -ry "$PROJECT_DIR/FinderRight-v$VERSION.zip" FinderRight.app)

echo "=== 构建完成！==="
echo "DMG 产物: $PROJECT_DIR/FinderRight.dmg (及 build/FinderRight-$VERSION.dmg)"
echo "ZIP 产物: $PROJECT_DIR/FinderRight-v$VERSION.zip"
