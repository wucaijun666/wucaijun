#!/bin/bash
# 构建 SundiroWidget.appex —— 必须在 macOS + Xcode 上运行（GitHub Actions macos runner）
# 用法: ./build_appex.sh [输出目录]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/build}"
APPEX="$OUT/SundiroWidget.appex"
MIN_IOS="17.0"

rm -rf "$OUT"
mkdir -p "$APPEX"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
echo "SDK = $SDK"

# ---- 1. 编译扩展可执行文件 -------------------------------------------------
xcrun --sdk iphoneos swiftc \
    -target "arm64-apple-ios${MIN_IOS}" \
    -sdk "$SDK" \
    -parse-as-library \
    -O -whole-module-optimization \
    -module-name SundiroWidget \
    -swift-version 5 \
    -o "$APPEX/SundiroWidget" \
    -framework WidgetKit \
    -framework SwiftUI \
    -framework Foundation \
    -Xlinker -rpath -Xlinker /usr/lib/swift \
    -Xlinker -e -Xlinker _NSExtensionMain \
    "$HERE/SundiroWidget.swift"

# ---- 2. Info.plist --------------------------------------------------------
cp "$HERE/Info.plist" "$APPEX/Info.plist"

# ---- 3. 校验：入口点、最低系统版本 ----------------------------------------
echo "--- LC_BUILD_VERSION / LC_MAIN ---"
otool -l "$APPEX/SundiroWidget" | grep -A4 -E 'LC_BUILD_VERSION|LC_MAIN' | head -20

echo "--- 入口符号 ---"
nm -gU "$APPEX/SundiroWidget" | grep -E ' _main$' || true

# ★ 必须导入 _NSExtensionMain，且 LC_MAIN 指向它的桩（app 扩展的进程入口）
echo "--- 扩展入口校验 ---"
if nm -u "$APPEX/SundiroWidget" | grep -q _NSExtensionMain; then
    echo "OK: 已导入 _NSExtensionMain"
else
    echo "FATAL: 没导入 _NSExtensionMain —— 扩展进程起不来"; exit 1
fi
ENTRYOFF=$(otool -l "$APPEX/SundiroWidget" | awk '/LC_MAIN/{f=1} f&&/entryoff/{print $2; exit}')
echo "LC_MAIN entryoff = $ENTRYOFF"
if [ "$ENTRYOFF" = "0" ] || [ -z "$ENTRYOFF" ]; then
    echo "FATAL: LC_MAIN 异常"; exit 1
fi

# ---- 4. ad-hoc 签名（带 entitlements，TrollStore 安装时会重新 ldid 签名）---
codesign -f -s - \
    --entitlements "$HERE/SundiroWidget.entitlements" \
    --timestamp=none \
    --generate-entitlement-der \
    "$APPEX"

echo "--- 签名校验 ---"
codesign -dv --entitlements - "$APPEX" 2>&1 | head -20

# ---- 5. 打包为 zip 供下载 -------------------------------------------------
( cd "$OUT" && /usr/bin/zip -qry SundiroWidget.appex.zip SundiroWidget.appex )
echo "OK -> $OUT/SundiroWidget.appex.zip"
ls -la "$OUT"