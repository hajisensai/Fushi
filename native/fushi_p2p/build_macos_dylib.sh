#!/usr/bin/env bash
# macOS 版 libfushi_p2p.dylib（universal：arm64 + x86_64），给 app bundle 的
# Contents/Frameworks 用（fushi/macos/bundle_fushi_p2p.sh 在 Xcode 构建阶段拷进去）。
#
# 用法: build_macos_dylib.sh [arch ...]   arch 取 arm64 / x86_64，缺省两者都编并 lipo
# 前提: rustup target add aarch64-apple-darwin x86_64-apple-darwin
# 产物: prebuilt/macos/libfushi_p2p.dylib（git 忽略，不入库；install name = @rpath/libfushi_p2p.dylib）
#
# 部署目标与 fushi/macos/Runner.xcodeproj 的 MACOSX_DEPLOYMENT_TARGET 对齐（13.4），
# 否则链接 Runner 时 ld 会对「dylib 比 app 要求更新的系统」报警、老系统上加载失败。
set -euo pipefail

if [[ $# -gt 0 ]]; then ARCHS=("$@"); else ARCHS=(arm64 x86_64); fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/prebuilt/macos"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.4}"

rust_target() {
  case "$1" in
    arm64) echo aarch64-apple-darwin ;;
    x86_64) echo x86_64-apple-darwin ;;
    *) echo "unsupported macOS arch: $1" >&2; exit 1 ;;
  esac
}

cd "$SCRIPT_DIR"
slices=()
for arch in "${ARCHS[@]}"; do
  target="$(rust_target "$arch")"
  # 只出 cdylib：Cargo.toml 同时声明了 staticlib（iOS 用），这里不必为它再跑一遍 fat LTO。
  echo "==> cargo rustc --release --lib --target $target --crate-type cdylib (MACOSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET)"
  cargo rustc --release --lib --target "$target" --crate-type cdylib
  slice="target/$target/release/libfushi_p2p.dylib"
  [[ -f "$slice" ]] || { echo "missing $slice" >&2; exit 1; }
  slices+=("$slice")
done

mkdir -p "$OUT_DIR"
out="$OUT_DIR/libfushi_p2p.dylib"
lipo -create "${slices[@]}" -output "$out"
install_name_tool -id "@rpath/libfushi_p2p.dylib" "$out"
lipo -info "$out"
otool -L "$out"
echo "==> Done: $out ($(wc -c < "$out") bytes)"
