#!/usr/bin/env bash
# macOS 版 libfushi_rwkv.dylib（只出 Apple Silicon arm64：macOS 版不再支持 Intel Mac），
# 给 app bundle 的 Contents/Frameworks 用（fushi/macos/bundle_fushi_rwkv.sh 在 Xcode
# 构建阶段拷进去）。与 native/fushi_compute/build_macos_dylib.sh 同一形态。
#
# 用法: build_macos_dylib.sh
# 前提: rustup target add aarch64-apple-darwin
# 产物: prebuilt/macos/libfushi_rwkv.dylib（git 忽略，不入库；install name = @rpath/libfushi_rwkv.dylib）
#
# 部署目标与 fushi/macos/Runner.xcodeproj 的 MACOSX_DEPLOYMENT_TARGET 对齐（13.4），
# 否则链接 Runner 时 ld 会对「dylib 比 app 要求更新的系统」报警、老系统上加载失败。
# macOS 上推理走 Accelerate（src/rwkv/matmul.rs），dylib 依赖系统 Accelerate.framework。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/prebuilt/macos"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.4}"

target=aarch64-apple-darwin

cd "$SCRIPT_DIR"
# 只出 cdylib：Cargo.toml 同时声明了 staticlib / rlib（iOS 伞形库用），这里不必为它们再跑一遍 fat LTO。
echo "==> cargo rustc --release --lib --target $target --crate-type cdylib (MACOSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET)"
# strip 交给下面的 /usr/bin/strip -x，不用 Cargo.toml 的 strip = true：理由同
# native/fushi_compute/build_macos_dylib.sh（rust-objcopy 重排 LINKEDIT 不补齐 8 字节对齐，
# SDK 27 链出的 dylib 会被 macOS 27 的 dyld 拒绝；verify_abi.sh 按链接 SDK 判对齐）。
CARGO_PROFILE_RELEASE_STRIP=false cargo rustc --release --lib --target "$target" --crate-type cdylib
built="target/$target/release/libfushi_rwkv.dylib"
[[ -f "$built" ]] || { echo "missing $built" >&2; exit 1; }

mkdir -p "$OUT_DIR"
out="$OUT_DIR/libfushi_rwkv.dylib"
cp -f "$built" "$out"
/usr/bin/strip -x "$out"
install_name_tool -id "@rpath/libfushi_rwkv.dylib" "$out"
# 产物必须真能被 dyld 加载并返回 ABI 版本：符号核对（verify_abi.sh）查不出 LINKEDIT 损坏。
# 期望值取自 src/lib.rs 的 ABI_VERSION，ABI 升级时不必改这里。
abi_expected="$(sed -n 's/^pub const ABI_VERSION: i32 = \([0-9][0-9]*\);.*/\1/p' src/lib.rs)"
[[ -n "$abi_expected" ]] || { echo "cannot read ABI_VERSION from src/lib.rs" >&2; exit 1; }
if command -v python3 >/dev/null 2>&1; then
  DYLIB_PATH="$out" ABI_EXPECTED="$abi_expected" python3 -c 'import ctypes, os; lib = ctypes.CDLL(os.environ["DYLIB_PATH"]); lib.frwkv_abi_version.restype = ctypes.c_int32; v = lib.frwkv_abi_version(); assert v == int(os.environ["ABI_EXPECTED"]), v; print("dlopen ok: frwkv_abi_version =", v)'
else
  echo "note: python3 not found; skipped the dlopen smoke check"
fi
lipo -info "$out"
otool -L "$out"
echo "==> Done: $out ($(wc -c < "$out") bytes)"
