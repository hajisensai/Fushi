#!/usr/bin/env bash
# Linux x86_64 版 libfushi_corpus.so（社区维护的 Linux 桌面进 bundle/lib/；CI 的 Linux 单测也用它）。
# 硬依赖：缺了它 Linux 桌面构建失败（无头服务端没有查词弹窗，不随包）。
#
# 用法: build_linux_so.sh [target]   缺省 x86_64-unknown-linux-gnu
# 产物: prebuilt/linux-x64/libfushi_corpus.so（git 忽略，不入库）
set -euo pipefail

TARGET="${1:-x86_64-unknown-linux-gnu}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/prebuilt/linux-x64"

cd "$SCRIPT_DIR"
echo "==> cargo build --release --target $TARGET"
cargo build --release --target "$TARGET"
mkdir -p "$OUT_DIR"
cp "target/$TARGET/release/libfushi_corpus.so" "$OUT_DIR/libfushi_corpus.so"
echo "==> Done: $OUT_DIR/libfushi_corpus.so ($(wc -c < "$OUT_DIR/libfushi_corpus.so") bytes)"
