#!/bin/bash
# 打包 右键工具箱.app（宿主 + Finder Sync 扩展 + 模板）并签名
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
APP_NAME="右键工具箱.app"
EXT_NAME="RightClickToolsExt.appex"
BUILD="$ROOT/build"
APP="$BUILD/$APP_NAME"
EXT="$APP/Contents/PlugIns/$EXT_NAME"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$EXT/Contents/MacOS" "$EXT/Contents/Resources"

echo "① 编译宿主程序（管理台 GUI，ARC）"
clang -arch arm64 -O2 -fobjc-arc -isysroot "$SDK" \
  -DUSER_HOME="\"$HOME\"" \
  -framework Foundation -framework AppKit -framework FinderSync \
  "$ROOT/src/HostMain.m" -o "$APP/Contents/MacOS/RightClickTools"
cp "$ROOT/resources/Host-Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/resources/helper.sh" "$APP/Contents/Resources/"
cp "$ROOT/resources/AppIcon.icns" "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "② 编译 Finder Sync 扩展"
clang -arch arm64 -O2 -fobjc-arc -isysroot "$SDK" \
  -DUSER_HOME="\"$HOME\"" \
  -framework Foundation -framework AppKit -framework FinderSync \
  -Wl,-e,_NSExtensionMain \
  "$ROOT/src/ExtMain.m" -o "$EXT/Contents/MacOS/RightClickToolsExt"
cp "$ROOT/resources/Ext-Info.plist" "$EXT/Contents/Info.plist"
printf 'XPC!????' > "$EXT/Contents/PkgInfo"

echo "③ 放入文档模板"
cp "$ROOT/templates/blank.docx" "$ROOT/templates/blank.xlsx" "$ROOT/templates/blank.pptx" "$EXT/Contents/Resources/"

echo "④ 代码签名（ad-hoc，本机自用；扩展必须带 App Sandbox，否则系统不收录）"
cat > "$BUILD/ext.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.files.user-selected.read-write</key>
	<true/>
</dict>
</plist>
PLIST
codesign --force --sign - --timestamp=none --entitlements "$BUILD/ext.entitlements" "$EXT"
codesign --force --sign - --timestamp=none "$APP"

echo "⑤ 校验"
codesign --verify --verbose=1 "$EXT" && codesign --verify --verbose=1 "$APP"
echo
echo "完成：$APP"
