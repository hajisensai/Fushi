#!/usr/bin/env bash
# 把 FakeAnkiMobile 编成 iOS 模拟器 .app 并装进指定模拟器（BUG-2493 iOS 实测用）。
# 不走 Xcode 工程：模拟器包不需要签名，swiftc + 手工 bundle 就够。
#
#   bash build_install.sh <simulator-udid> [out-dir]
#
# 装完顺手把请求计数归零（main.swift 按第 N 次请求切换三种回跳形态）。
set -euo pipefail

udid="${1:?simulator udid required}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="${2:-"$here/build"}"
app="$out/FakeAnkiMobile.app"
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
arch="$(uname -m)"
target="${arch}-apple-ios16.0-simulator"

rm -rf "$app"
mkdir -p "$app"
swiftc -sdk "$sdk" -target "$target" -parse-as-library \
  -o "$app/FakeAnkiMobile" "$here/main.swift"
cp "$here/Info.plist" "$app/Info.plist"
printf 'APPL????' > "$app/PkgInfo"

xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl install "$udid" "$app"
xcrun simctl spawn "$udid" defaults delete app.fushi.fakeankimobile 2>/dev/null || true
echo "installed $app into $udid (request counter reset)"
