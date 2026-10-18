#!/usr/bin/env bash
# macOS 版 libfushi_compute.dylib（只出 Apple Silicon arm64：macOS 版不再支持 Intel Mac），
# 给 app bundle 的 Contents/Frameworks 用（fushi/macos/bundle_fushi_compute.sh 在 Xcode
# 构建阶段拷进去）。
#
# 用法: build_macos_dylib.sh
# 前提: rustup target add aarch64-apple-darwin
# 产物: prebuilt/macos/libfushi_compute.dylib（git 忽略，不入库；install name = @rpath/libfushi_compute.dylib）
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
# strip 交给下面的 /usr/bin/strip -x，不用 Cargo.toml 的 strip = true：实测（macOS 27.2 + 当前
# Xcode，2026-10-18）只要设了 MACOSX_DEPLOYMENT_TARGET，rustc 自己 strip 出来的 dylib 会被 dyld
# 以「mis-aligned LINKEDIT string pool」拒绝加载（文件、符号、install name 都正常，只有 dlopen 失败）；
# 不 strip 再手动 strip -x 的同一份产物加载正常、体积相同。下面的 dlopen 冒烟兜住这类回归。
CARGO_PROFILE_RELEASE_STRIP=false cargo rustc --release --lib --target "$target" --crate-type cdylib
built="target/$target/release/libfushi_compute.dylib"
[[ -f "$built" ]] || { echo "missing $built" >&2; exit 1; }

mkdir -p "$OUT_DIR"
out="$OUT_DIR/libfushi_compute.dylib"
cp -f "$built" "$out"
strip -x "$out"
install_name_tool -id "@rpath/libfushi_compute.dylib" "$out"
# 产物必须真能被 dyld 加载并返回 ABI 版本：符号核对（verify_abi.sh）查不出 LINKEDIT 损坏。
if command -v python3 >/dev/null 2>&1; then
  DYLIB_PATH="$out" python3 -c 'import ctypes, os; lib = ctypes.CDLL(os.environ["DYLIB_PATH"]); lib.ffc_abi_version.restype = ctypes.c_int32; v = lib.ffc_abi_version(); assert v == 1, v; print("dlopen ok: ffc_abi_version =", v)'
else
  echo "note: python3 not found; skipped the dlopen smoke check"
fi
lipo -info "$out"
otool -L "$out"
echo "==> Done: $out ($(wc -c < "$out") bytes)"
