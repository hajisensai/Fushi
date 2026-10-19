#!/usr/bin/env bash
# macOS 版 libfushi_p2p.dylib（只出 Apple Silicon arm64：macOS 版不再支持 Intel Mac），
# 给 app bundle 的 Contents/Frameworks 用（fushi/macos/bundle_fushi_p2p.sh 在 Xcode
# 构建阶段拷进去）。
#
# 用法: build_macos_dylib.sh
# 前提: rustup target add aarch64-apple-darwin
# 产物: prebuilt/macos/libfushi_p2p.dylib（git 忽略，不入库；install name = @rpath/libfushi_p2p.dylib）
#
# 部署目标与 fushi/macos/Runner.xcodeproj 的 MACOSX_DEPLOYMENT_TARGET 对齐（13.4），
# 否则链接 Runner 时 ld 会对「dylib 比 app 要求更新的系统」报警、老系统上加载失败。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/prebuilt/macos"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.4}"

target=aarch64-apple-darwin

cd "$SCRIPT_DIR"
# 只出 cdylib：Cargo.toml 同时声明了 staticlib（iOS 用），这里不必为它再跑一遍 fat LTO。
echo "==> cargo rustc --release --lib --target $target --crate-type cdylib (MACOSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET)"
# CARGO_PROFILE_RELEASE_STRIP=false：cargo（rustc）strip 出来的 dylib 在新工具链的 macOS 上加载即报
# 「mis-aligned LINKEDIT string pool」（实测 macOS 27.2 / Xcode 27.1 / rustc 1.95），verify_abi.sh 的
# 符号核对查不出来。改由下面 Apple 的 /usr/bin/strip -x 去本地符号（Xcode 27 的实测会补齐，更旧 Xcode 的
# 不保证——2026-10-19 macos-latest 出包 stroff mod 8 = 4；写绝对路径免得 PATH 上的 llvm-strip 顶替），
# 体积与 cargo strip 相当。verify_abi.sh 按二进制自己记录的链接 SDK 判 LINKEDIT 对齐：SDK ≥ 27
# （dyld 会校验）未对齐即红，更旧 SDK 只告警。
CARGO_PROFILE_RELEASE_STRIP=false cargo rustc --release --lib --target "$target" --crate-type cdylib
built="target/$target/release/libfushi_p2p.dylib"
[[ -f "$built" ]] || { echo "missing $built" >&2; exit 1; }

mkdir -p "$OUT_DIR"
out="$OUT_DIR/libfushi_p2p.dylib"
cp -f "$built" "$out"
/usr/bin/strip -x "$out"
install_name_tool -id "@rpath/libfushi_p2p.dylib" "$out"
# 真加载一次：坏掉的 LINKEDIT 只有 dlopen 才暴露（nm / otool 照样读得出符号）。
python3 -c 'import ctypes, sys; ctypes.CDLL(sys.argv[1])' "$out" || {
  echo "dlopen failed: $out" >&2
  exit 1
}
lipo -info "$out"
otool -L "$out"
echo "==> Done: $out ($(wc -c < "$out") bytes)"
