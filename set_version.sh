#!/bin/bash
# 统一改写宿主与扩展的版本号，避免两处 plist 版本不一致
# 用法: bash set_version.sh <版本号> [build号]
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
VER="$1"
BUILD="${2:-1}"

if [ -z "$VER" ]; then
  echo "用法: bash set_version.sh <版本号> [build号]" >&2
  exit 1
fi

for p in "$ROOT/resources/Host-Info.plist" "$ROOT/resources/Ext-Info.plist"; do
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VER" "$p"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$p"
  echo "$(basename "$p") → $VER ($BUILD)"
done
