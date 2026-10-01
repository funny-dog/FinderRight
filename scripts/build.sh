#!/usr/bin/env bash
set -euo pipefail

# 注意：当前构建目标指定为 arm64-apple-macos13.0（仅支持 Apple Silicon 架构）。
# 未构建 Universal Binary（x86_64 + arm64），因此编译产物仅适用于 Apple Silicon (M 系列芯片) Mac，Intel Mac 无法直接运行。

# 根目录
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PROJECT_DIR/FinderRight/Info.plist")
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PROJECT_DIR/FinderRight/Info.plist")
STAGE_DIR="$PROJECT_DIR/build/dmg-stage"
APP_DIR="$STAGE_DIR/FinderRight.app"
APPEX_DIR="$APP_DIR/Contents/PlugIns/FinderRightSync.appex"
KIT_BUILD_DIR="$PROJECT_DIR/FinderRightKit/.build/out/Products/Release"

echo "=== 1. 编译 FinderRightKit (Release) ==="
swift build -c release --disable-sandbox --package-path FinderRightKit

# 复用唯一 staging App，逐个覆盖编译产物；避免对已有 bundle 做批量删除。
# 资源是否存在由下方硬校验确认，不依赖历史产物。
mkdir -p "$STAGE_DIR"

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

# 同步主 App 版本号到扩展 Info.plist（单一版本来源）
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APPEX_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APPEX_DIR/Contents/Info.plist"

echo -n "XPC!????" > "$APPEX_DIR/Contents/PkgInfo"
mkdir -p "$APPEX_DIR/Contents/Resources/en.lproj"
cp FinderRightSync/en.lproj/Localizable.strings "$APPEX_DIR/Contents/Resources/en.lproj/"
if [ -f "FinderRightSync/cut-badge.png" ]; then
  cp FinderRightSync/cut-badge.png "$APPEX_DIR/Contents/Resources/"
fi

echo "=== 5. 代码签名 (Ad-hoc) ==="
# 注意：严禁在对主 App 签名时使用 --deep！
# --deep 会递归进入 PlugIns 目录，用主 App 的无沙箱配置覆盖抹除 FinderRightSync 的 app-sandbox 权限，
# 导致 PluginKit 判定扩展未开启沙箱而静默拒绝加载（pluginkit 输出 no matches，右键菜单彻底消失）。
# 正确方式：自内向外（Inside-Out）逐层独立签名：
#
# -o runtime（Hardened Runtime）必须保留：主 App 持有完全磁盘访问与辅助功能授权，未加固时 dyld 会接受
# DYLD_INSERT_LIBRARIES，同用户恶意程序用 `open --env` 拉起本 App 即可注入代码并继承这两项授权。
# Kit 为静态库、主程序只链接系统库，库验证不受影响；主 App 不发 AppleEvent，无需额外 entitlement。
codesign -s - --force -o runtime --entitlements FinderRightSync/FinderRightSync.entitlements "$APPEX_DIR"
codesign -s - --force -o runtime --entitlements FinderRight/FinderRight.entitlements "$APP_DIR"

# 硬校验：签名有效且两者都带 runtime 标志，否则立即构建失败，不让加固静默回退
codesign --verify --strict "$APP_DIR"
for bundle in "$APP_DIR" "$APPEX_DIR"; do
  # 先取完整输出再匹配：pipefail 下 `codesign | grep -q` 会因 grep 提前退出、codesign 收到 SIGPIPE 而误判失败
  sig_info="$(codesign -dv "$bundle" 2>&1)"
  if [[ "$sig_info" != *"flags="*"runtime"* ]]; then
    echo "错误：$bundle 未启用 Hardened Runtime" >&2
    exit 1
  fi
done

echo "=== 6. 创建 Applications 软链接 ==="
ln -shf /Applications "$STAGE_DIR/Applications"

echo "=== 7. 打包 DMG 与 ZIP ==="
mkdir -p "$PROJECT_DIR/build"
rm -f "$PROJECT_DIR/build/FinderRight-$VERSION.dmg" "$PROJECT_DIR/FinderRight.dmg" "$PROJECT_DIR/FinderRight-v$VERSION.zip" "$PROJECT_DIR/FinderRight-v$VERSION.zip.sha256"

hdiutil create -volname "FinderRight" -srcfolder "$STAGE_DIR" -ov -format UDZO "$PROJECT_DIR/build/FinderRight-$VERSION.dmg"
cp "$PROJECT_DIR/build/FinderRight-$VERSION.dmg" "$PROJECT_DIR/FinderRight.dmg"

(cd "$STAGE_DIR" && zip -ry "$PROJECT_DIR/FinderRight-v$VERSION.zip" FinderRight.app)
(cd "$PROJECT_DIR" && shasum -a 256 "FinderRight-v$VERSION.zip" > "FinderRight-v$VERSION.zip.sha256")

echo "=== 构建完成！==="
echo "DMG 产物: $PROJECT_DIR/FinderRight.dmg (及 build/FinderRight-$VERSION.dmg)"
echo "ZIP 产物: $PROJECT_DIR/FinderRight-v$VERSION.zip"
echo "SHA256:  $PROJECT_DIR/FinderRight-v$VERSION.zip.sha256"
