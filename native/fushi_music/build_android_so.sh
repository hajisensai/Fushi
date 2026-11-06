#!/usr/bin/env bash
# CI（Linux/macOS）版 Android .so 构建：与 build_android_so.ps1 同一套流程/产物布局。
#
# 用法: build_android_so.sh <ndk-root> [abi ...]
#   abi 缺省 arm64-v8a x86_64（本机调试够用）。发布（release.yml）与 PR 门
#   （（音乐库尚未接 PR 门））传 arm64-v8a armeabi-v7a x86_64，与 split-per-abi APK 对齐。
#   产物: prebuilt/android/<abi>/libfushi_music.so
# 前提: rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android;
#       cargo install cargo-ndk（CI 钉 4.1.2）
set -euo pipefail

NDK_ROOT="${1:?usage: build_android_so.sh <ndk-root> [abi ...]}"
shift
if [[ $# -gt 0 ]]; then ABIS=("$@"); else ABIS=(arm64-v8a x86_64); fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/prebuilt/android"

export ANDROID_NDK_HOME="$NDK_ROOT"
API=24

# rquickjs-sys 没有 Android 的预生成绑定，Android 上开 bindgen（Cargo.toml）。bindgen 不带版本号
# 地把 Rust 三元组当 clang --target（aarch64-linux-android），NDK r28+ 的 sys/cdefs.h 直接
# #error「Unversioned target triples are not supported!」。cargo-ndk 4.1.2 只把
# BINDGEN_EXTRA_CLANG_ARGS_<下划线三元组> 设成 --sysroot（覆盖我们设的同名变量），而 bindgen
# 先查连字符形式的 BINDGEN_EXTRA_CLANG_ARGS_<三元组>：在那里给带 API 级别的 --target（bindgen
# 见到显式 --target 就不再自己加）连同 sysroot / 架构头文件目录。
case "$(uname -s)" in
  Linux) HOST_TAG=linux-x86_64 ;;
  Darwin) HOST_TAG=darwin-x86_64 ;;
  *) HOST_TAG=windows-x86_64 ;;
esac
SYSROOT="$NDK_ROOT/toolchains/llvm/prebuilt/$HOST_TAG/sysroot"
bindgen_env=()
for abi in "${ABIS[@]}"; do
  case "$abi" in
    arm64-v8a) rust=aarch64-linux-android clang=aarch64-linux-android inc=aarch64-linux-android ;;
    armeabi-v7a) rust=armv7-linux-androideabi clang=armv7a-linux-androideabi inc=arm-linux-androideabi ;;
    x86_64) rust=x86_64-linux-android clang=x86_64-linux-android inc=x86_64-linux-android ;;
    x86) rust=i686-linux-android clang=i686-linux-android inc=i686-linux-android ;;
    *) echo "unknown ABI $abi" >&2; exit 1 ;;
  esac
  bindgen_env+=("BINDGEN_EXTRA_CLANG_ARGS_${rust}=--target=${clang}${API} --sysroot=$SYSROOT -I$SYSROOT/usr/include/${inc}")
done

args=(ndk --platform "$API" -o "$OUT_DIR")
for abi in "${ABIS[@]}"; do args+=(-t "$abi"); done
args+=(build --release)

cd "$SCRIPT_DIR"
echo "==> cargo ${args[*]}"
# 连字符变量名 bash 不能 export，经 env 传给 cargo。
env "${bindgen_env[@]}" cargo "${args[@]}"
for abi in "${ABIS[@]}"; do
  # cargo-ndk 顺带拷出的依赖 cdylib 副本无人加载（见 .ps1 版注释）。
  find "$OUT_DIR/$abi" -name '*.so' ! -name libfushi_music.so -delete
  so="$OUT_DIR/$abi/libfushi_music.so"
  [[ -f "$so" ]] || { echo "missing $so" >&2; exit 1; }
  echo "  $so $(wc -c < "$so") bytes"
done
