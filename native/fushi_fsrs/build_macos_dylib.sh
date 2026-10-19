#!/usr/bin/env bash
# macOS 版 libfushi_fsrs.dylib（只出 Apple Silicon arm64：macOS 版不再支持 Intel Mac），
# 给 app bundle 的 Contents/Frameworks 用（fushi/macos/bundle_fushi_fsrs.sh 在 Xcode
# 构建阶段拷进去）。
#
# 用法: build_macos_dylib.sh
# 前提: rustup target add aarch64-apple-darwin
# 产物: prebuilt/macos/libfushi_fsrs.dylib（git 忽略，不入库；install name = @rpath/libfushi_fsrs.dylib）
#
# 部署目标与 fushi/macos/Runner.xcodeproj 的 MACOSX_DEPLOYMENT_TARGET 对齐（13.4），
# 否则链接 Runner 时 ld 会对「dylib 比 app 要求更新的系统」报警、老系统上加载失败。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/prebuilt/macos"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.4}"

target=aarch64-apple-darwin

cd "$SCRIPT_DIR"
# 只出 cdylib：Cargo.toml 同时声明了 staticlib / rlib（iOS 伞形库用），这里不必为它们再跑一遍 fat LTO。
echo "==> cargo rustc --release --lib --target $target --crate-type cdylib (MACOSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET)"
# 本地符号由链接器去（-Wl,-x），install name 也在链接时定（-Wl,-install_name），产物不再经任何
# 事后改写 LINKEDIT 的工具：cargo strip（rust-objcopy）重排 LINKEDIT 不补齐，间接符号表项数为奇数时
# 字符串表只对齐到 4，macOS 27 的 dyld 以「mis-aligned LINKEDIT string pool」拒绝加载；改用
# /usr/bin/strip -x 也不可靠——runner（macos-latest）的 strip 同样不补齐，fushi_fsrs 加进 regex 后
# 字符串表偏移落在 4 (mod 8) 上，develop 的 macOS 出包因此被 verify_abi.sh 拦下。ld 自己产出的
# LINKEDIT 按 8 字节布局。verify_abi.sh 的 LINKEDIT 对齐检查与 runner 系统无关地兜住这类回归。
CARGO_PROFILE_RELEASE_STRIP=false cargo rustc --release --lib --target "$target" --crate-type cdylib -- \
  -C link-arg=-Wl,-x -C link-arg=-Wl,-install_name,@rpath/libfushi_fsrs.dylib
built="target/$target/release/libfushi_fsrs.dylib"
[[ -f "$built" ]] || { echo "missing $built" >&2; exit 1; }

mkdir -p "$OUT_DIR"
out="$OUT_DIR/libfushi_fsrs.dylib"
cp -f "$built" "$out"
# 真加载一次：坏掉的 LINKEDIT 只有 dlopen 才暴露（nm / otool 照样读得出符号）。
python3 -c 'import ctypes, sys; ctypes.CDLL(sys.argv[1])' "$out" || {
  echo "dlopen failed: $out" >&2
  exit 1
}
lipo -info "$out"
otool -L "$out"
echo "==> Done: $out ($(wc -c < "$out") bytes)"
