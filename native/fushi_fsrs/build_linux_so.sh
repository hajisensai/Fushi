#!/usr/bin/env bash
# Linux x86_64 版 libfushi_fsrs.so（无头服务端 bundle 随包：bin/../lib/libfushi_fsrs.so；
# 社区维护的 Linux 桌面 copy-if-present 进 bundle/lib/）。
#
# 用法: build_linux_so.sh [target]   缺省 x86_64-unknown-linux-gnu
# 产物: prebuilt/linux-x64/libfushi_fsrs.so（git 忽略，不入库）
# 环境变量 FUSHI_FSRS_FEATURES（可选）：额外的 cargo feature，只给测试用的库——CI 包测试用
# `id_audit` 编（Dart 经桥执行的 SQL 绑了文本 UUID / 写进文本 UUID 就报错，见 src/store/ids.rs `audit`）。
# 随包发布的构建不设它。
set -euo pipefail

TARGET="${1:-x86_64-unknown-linux-gnu}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/prebuilt/linux-x64"
FEATURES=()
if [ -n "${FUSHI_FSRS_FEATURES:-}" ]; then
  FEATURES=(--features "$FUSHI_FSRS_FEATURES")
fi

cd "$SCRIPT_DIR"
echo "==> cargo build --release --target $TARGET ${FEATURES[*]:-}"
cargo build --release --target "$TARGET" "${FEATURES[@]}"
mkdir -p "$OUT_DIR"
cp "target/$TARGET/release/libfushi_fsrs.so" "$OUT_DIR/libfushi_fsrs.so"
echo "==> Done: $OUT_DIR/libfushi_fsrs.so ($(wc -c < "$OUT_DIR/libfushi_fsrs.so") bytes)"
