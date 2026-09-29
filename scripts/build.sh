#!/usr/bin/env bash
set -euo pipefail

# 根目录
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

VERSION="1.1.5"
STAGE_DIR="$PROJECT_DIR/build/dmg-stage"
APP_DIR="$STAGE_DIR/FinderRight.app"
APPEX_DIR="$APP_DIR/Contents/PlugIns/FinderRightSync.appex"
KIT_BUILD_DIR="$PROJECT_DIR/FinderRightKit/.build/out/Products/Release"

echo "=== 1. 编译 FinderRightKit (Release) ==="
swift build -c release --package-path FinderRightKit

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
