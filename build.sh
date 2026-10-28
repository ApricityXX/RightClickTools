#!/bin/bash
# 打包 右键工具箱.app（宿主 + Finder Sync 扩展 + 模板）并签名
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
# SDK 路径自适应：优先环境变量，其次 Command Line Tools，最后退回 xcrun（GitHub Actions 上通常是 Xcode 的 SDK）
SDK="${SDK:-}"
if [ -z "$SDK" ]; then
  if [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk ]; then
    SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
  else
    SDK="$(xcrun --show-sdk-path)"
  fi
fi
ARCH="${ARCH:-$(uname -m)}"   # 默认沿用当前机器架构，可用 ARCH=x86_64 覆盖
# 部署目标必须显式指定：否则 CI 在 macOS 14/15 运行器上编译出的二进制 minos 会等于构建机系统版本，
# 在更低版本 macOS 上打开会报 -10825 kLSIncompatibleSystemVersionErr
MACOS_MIN="${MACOS_MIN:-13.0}"
APP_NAME="右键工具箱.app"
EXT_NAME="RightClickToolsExt.appex"
BUILD="$ROOT/build"
APP="$BUILD/$APP_NAME"
EXT="$APP/Contents/PlugIns/$EXT_NAME"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$EXT/Contents/MacOS" "$EXT/Contents/Resources"

echo "① 编译宿主程序（管理台 GUI，ARC）"
clang -arch "$ARCH" -mmacosx-version-min="$MACOS_MIN" -O2 -fobjc-arc -isysroot "$SDK" \
  -DUSER_HOME="\"$HOME\"" \
  -framework Foundation -framework AppKit -framework FinderSync \
  "$ROOT/src/HostMain.m" -o "$APP/Contents/MacOS/RightClickTools"
cp "$ROOT/resources/Host-Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/resources/helper.sh" "$APP/Contents/Resources/"
cp "$ROOT/resources/AppIcon.icns" "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "② 编译 Finder Sync 扩展"
clang -arch "$ARCH" -mmacosx-version-min="$MACOS_MIN" -O2 -fobjc-arc -isysroot "$SDK" \
  -DUSER_HOME="\"$HOME\"" \
  -framework Foundation -framework AppKit -framework FinderSync \
  -Wl,-e,_NSExtensionMain \
  "$ROOT/src/ExtMain.m" -o "$EXT/Contents/MacOS/RightClickToolsExt"
cp "$ROOT/resources/Ext-Info.plist" "$EXT/Contents/Info.plist"
printf 'XPC!????' > "$EXT/Contents/PkgInfo"

echo "③ 放入文档模板"
cp "$ROOT/templates/blank.docx" "$ROOT/templates/blank.xlsx" "$ROOT/templates/blank.pptx" "$EXT/Contents/Resources/"

echo "④ 代码签名（扩展必须带 App Sandbox，否则系统不收录）"
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
