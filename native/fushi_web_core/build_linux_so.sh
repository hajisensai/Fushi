#!/usr/bin/env bash
# Linux x86_64 版 libfushi_web_core.so（Linux 桌面 bundle 的 bundle/lib/；CI 上 flutter / dart 单测经
# FUSHI_WEB_CORE_LIB 加载它）。
#
# 用法: build_linux_so.sh [target]   缺省 x86_64-unknown-linux-gnu
# 产物: prebuilt/linux-x64/libfushi_web_core.so（git 忽略，不入库）
set -euo pipefail

TARGET="${1:-x86_64-unknown-linux-gnu}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/prebuilt/linux-x64"

cd "$SCRIPT_DIR"
echo "==> cargo build --release --target $TARGET"
cargo build --release --target "$TARGET"
mkdir -p "$OUT_DIR"
cp "target/$TARGET/release/libfushi_web_core.so" "$OUT_DIR/libfushi_web_core.so"
echo "==> Done: $OUT_DIR/libfushi_web_core.so ($(wc -c < "$OUT_DIR/libfushi_web_core.so") bytes)"
