#!/usr/bin/env bash
# CI（Linux/macOS）版 Android .so 构建：与 build_android_so.ps1 同一套流程/产物布局。
#
# 用法: build_android_so.sh <ndk-root> [abi ...]
#   abi 缺省 arm64-v8a x86_64（本机调试够用）。发布（release.yml）与 PR 门
#   （native-fsrs-gate.yml）传 arm64-v8a armeabi-v7a x86_64，与 split-per-abi APK 对齐。
#   产物: prebuilt/android/<abi>/libfushi_fsrs.so
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
  # cargo-ndk 顺带拷出的依赖 cdylib 副本无人加载（见 .ps1 版注释）。
  find "$OUT_DIR/$abi" -name '*.so' ! -name libfushi_fsrs.so -delete
  so="$OUT_DIR/$abi/libfushi_fsrs.so"
  [[ -f "$so" ]] || { echo "missing $so" >&2; exit 1; }
  # libsqlite3-sys 给 Android 硬编码 TEMP_STORE=3（临时库全进内存，大库 VACUUM 撑爆进程）；.cargo/config.toml
  # 改回 1。从别的目录构建会丢那份配置，这里按产物里的编译选项字符串核对。
  # 按字节找（LC_ALL=C：UTF-8 locale 下 grep 对二进制里的非法序列另有处理）；sqlite3azCompileOpt 里恰有一条。
  temp_store="$(LC_ALL=C grep -aoE 'TEMP_STORE=[0-9]' "$so" | sort -u | tr '\n' ' ')"
  if [[ "$temp_store" != "TEMP_STORE=1 " ]]; then
    echo "$so: bundled SQLite compile options say '${temp_store}', expected 'TEMP_STORE=1' (see native/fushi_fsrs/.cargo/config.toml)" >&2
    exit 1
  fi
  echo "  $so $(wc -c < "$so") bytes"
done
