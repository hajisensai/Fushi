#!/usr/bin/env bash
# CI（Linux/macOS）版 Android .so 构建：与 build_android_so.ps1 同一套流程/产物布局。
#
# 用法: build_android_so.sh <ndk-root> [abi ...]
#   abi 缺省 arm64-v8a x86_64（本机调试够用）。发布（release.yml）与 PR 门
#   （native-p2p-gate.yml）传 arm64-v8a armeabi-v7a x86_64，与 split-per-abi APK 对齐。
#   产物: prebuilt/android/<abi>/libfushi_p2p.so
# 前提: rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android;
#       cargo install cargo-ndk（CI 钉 4.1.2）
set -euo pipefail

NDK_ROOT="${1:?usage: build_android_so.sh <ndk-root> [abi ...]}"
shift
if [[ $# -gt 0 ]]; then ABIS=("$@"); else ABIS=(arm64-v8a x86_64); fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/prebuilt/android"

export ANDROID_NDK_HOME="$NDK_ROOT"
args=(ndk --platform 24 -o "$OUT_DIR")
for abi in "${ABIS[@]}"; do args+=(-t "$abi"); done
args+=(build --release)

cd "$SCRIPT_DIR"
echo "==> cargo ${args[*]}"
cargo "${args[@]}"
for abi in "${ABIS[@]}"; do
  # cargo-ndk 顺带拷出的 libiroh-<hash>.so 等 cdylib 副本无人加载（见 .ps1 版注释）。
  find "$OUT_DIR/$abi" -name '*.so' ! -name libfushi_p2p.so -delete
  so="$OUT_DIR/$abi/libfushi_p2p.so"
  [[ -f "$so" ]] || { echo "missing $so" >&2; exit 1; }
  echo "  $so $(wc -c < "$so") bytes"
done
