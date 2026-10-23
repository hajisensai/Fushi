#!/usr/bin/env bash
# Linux x86_64 版 libfushi_rwkv.so（无头服务端 bundle 随包：bin/../lib/libfushi_rwkv.so；
# 社区维护的 Linux 桌面进 bundle/lib/）。硬依赖：两边缺了它都构建失败。
# 与 native/fushi_compute/build_linux_so.sh 同一形态。
#
# 用法: build_linux_so.sh [target]   缺省 x86_64-unknown-linux-gnu
# 产物: prebuilt/linux-x64/libfushi_rwkv.so（git 忽略，不入库）
set -euo pipefail

TARGET="${1:-x86_64-unknown-linux-gnu}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/prebuilt/linux-x64"

cd "$SCRIPT_DIR"
# 只出 cdylib：Cargo.toml 同时声明了 staticlib / rlib（iOS 伞形库用），这里不必为它们再跑一遍 fat LTO。
echo "==> cargo rustc --release --lib --target $TARGET --crate-type cdylib"
cargo rustc --release --lib --target "$TARGET" --crate-type cdylib
mkdir -p "$OUT_DIR"
cp "target/$TARGET/release/libfushi_rwkv.so" "$OUT_DIR/libfushi_rwkv.so"
echo "==> Done: $OUT_DIR/libfushi_rwkv.so ($(wc -c < "$OUT_DIR/libfushi_rwkv.so") bytes)"
