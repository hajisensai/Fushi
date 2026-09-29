#!/usr/bin/env bash
# Linux x86_64 版 libfushi_p2p.so（无头服务端 bundle 随包：bin/../lib/libfushi_p2p.so）。
#
# 用法: build_linux_so.sh [target]   缺省 x86_64-unknown-linux-gnu
# 产物: prebuilt/linux-x64/libfushi_p2p.so（git 忽略，不入库）
set -euo pipefail

TARGET="${1:-x86_64-unknown-linux-gnu}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/prebuilt/linux-x64"

cd "$SCRIPT_DIR"
echo "==> cargo build --release --target $TARGET"
cargo build --release --target "$TARGET"
mkdir -p "$OUT_DIR"
cp "target/$TARGET/release/libfushi_p2p.so" "$OUT_DIR/libfushi_p2p.so"
echo "==> Done: $OUT_DIR/libfushi_p2p.so ($(wc -c < "$OUT_DIR/libfushi_p2p.so") bytes)"
