#!/bin/bash
# NetWatch 一键出包：编译 main.swift → 组装 NetWatch.app（含后台脚本+图标）→ 打成可拖拽安装的 .dmg
# 用法：scripts/build.sh   （在仓库根目录或任意目录均可，脚本会自行定位仓库根）
# 产物：dist/NetWatch.app 和 dist/NetWatch-vX.X.dmg
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-$(cat VERSION 2>/dev/null || echo 5.2)}"
APP_NAME="NetWatch"
DISPLAY_NAME="网络体检"
BUNDLE_ID="com.jianlin.netwatch.app"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

echo "==> NetWatch v$VERSION 构建开始"
rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/backend"

FRAMEWORKS=(-framework SwiftUI -framework AppKit -framework Combine -framework CoreFoundation -framework Foundation)

echo "==> 编译 arm64"
swiftc main.swift -O -o "$DIST/NetWatch-arm64" "${FRAMEWORKS[@]}" -target arm64-apple-macos13.0

if swiftc main.swift -O -o "$DIST/NetWatch-x86_64" "${FRAMEWORKS[@]}" -target x86_64-apple-macos13.0 2>/dev/null; then
  echo "==> 编译 x86_64 成功，合成 universal 二进制"
  lipo -create "$DIST/NetWatch-arm64" "$DIST/NetWatch-x86_64" -output "$APP/Contents/MacOS/NetWatch"
else
  echo "==> x86_64 跳过（缺 SDK），仅 arm64"
  cp "$DIST/NetWatch-arm64" "$APP/Contents/MacOS/NetWatch"
fi
rm -f "$DIST/NetWatch-arm64" "$DIST/NetWatch-x86_64"
chmod +x "$APP/Contents/MacOS/NetWatch"

echo "==> 拷入图标 + 后台脚本"
cp icon.icns "$APP/Contents/Resources/icon.icns"
cp netwatch.sh risk_check.sh proxy_detect.sh "$APP/Contents/Resources/backend/"
chmod +x "$APP/Contents/Resources/backend/"*.sh

echo "==> 写 Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>NetWatch</string>
  <key>CFBundleIconFile</key><string>icon</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict></plist>
PLIST

echo "==> 清扩展属性 + ad-hoc 签名"
xattr -cr "$APP" 2>/dev/null || true
codesign -s - --force --deep "$APP"

echo "==> 打 .dmg（含 /Applications 拖拽快捷方式）"
DMG="$DIST/$APP_NAME-v$VERSION.dmg"
STAGE="$DIST/.dmg_stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$DISPLAY_NAME $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo ""
echo "✅ 构建完成"
echo "   App : $APP"
echo "   DMG : $DMG"
