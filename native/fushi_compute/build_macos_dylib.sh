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
# strip 与 install name 的做法有讲究（macOS 27.2 / Xcode 27.1 / rustc 1.95 实测，2026-10-24）：
# dyld-27102 对链接 SDK ≥ 27 的 Mach-O 要求 LINKEDIT 的字符串表（string pool）起点 8 字节对齐，
# 否则 dlopen 报「mis-aligned LINKEDIT string pool」。Apple ld 自己的输出是对齐的；弄坏它的是
# rustc 的 -C strip：它在 Apple 目标上链接后调 rust-objcopy（debuginfo 即 --strip-debug），重排
# LINKEDIT 时字符串表紧跟间接符号表（每项 4 字节），项数为奇数就只对齐到 4——部署目标、依赖
# 一变项数就可能翻奇偶，所以以前「换个写法就好了」都是碰巧。cargo 在 release（debug = 0）下即使
# profile 写 strip = false / "none"（或设 CARGO_PROFILE_RELEASE_STRIP）也照样给最终 crate 传
# -C strip=debuginfo（`cargo rustc -v` 可见），只能在 rustc 参数末尾用 -C strip=none 覆盖（同一
# -C 选项后者生效）。去本地符号交给 Apple 的 /usr/bin/strip -x（输入对齐时输出也对齐；写绝对
# 路径，免得 PATH 上的 llvm-strip 顶替）；install name 在链接时由 ld 的 -install_name 设好，不再
# 事后 install_name_tool 改写。verify_abi.sh 按 dyld 的同一套规则静态核对对齐；下面的 dlopen
# 冒烟只有在 macOS 27 上才测得出这一个问题。
cargo rustc --release --lib --target "$target" --crate-type cdylib -- \
  -C strip=none -C "link-arg=-Wl,-install_name,@rpath/libfushi_compute.dylib"
built="target/$target/release/libfushi_compute.dylib"
[[ -f "$built" ]] || { echo "missing $built" >&2; exit 1; }

mkdir -p "$OUT_DIR"
out="$OUT_DIR/libfushi_compute.dylib"
cp -f "$built" "$out"
/usr/bin/strip -x "$out"
# 产物必须真能被 dyld 加载并返回 ABI 版本：符号核对（verify_abi.sh）查不出 LINKEDIT 损坏。
# 期望值从 src/lib.rs 的 ABI_VERSION 读（与 workflow 里的冒烟同口径），升 ABI 不必再改这里。
if command -v python3 >/dev/null 2>&1; then
  abi_expected="$(sed -n 's/^pub const ABI_VERSION: i32 = \([0-9][0-9]*\);.*/\1/p' "$SCRIPT_DIR/src/lib.rs")"
  [[ -n "$abi_expected" ]] || { echo "cannot read ABI_VERSION from $SCRIPT_DIR/src/lib.rs" >&2; exit 1; }
  DYLIB_PATH="$out" ABI_EXPECTED="$abi_expected" python3 -c 'import ctypes, os; lib = ctypes.CDLL(os.environ["DYLIB_PATH"]); lib.ffc_abi_version.restype = ctypes.c_int32; v = lib.ffc_abi_version(); assert v == int(os.environ["ABI_EXPECTED"]), v; print("dlopen ok: ffc_abi_version =", v)'
else
  echo "note: python3 not found; skipped the dlopen smoke check"
fi
lipo -info "$out"
otool -L "$out"
echo "==> Done: $out ($(wc -c < "$out") bytes)"
