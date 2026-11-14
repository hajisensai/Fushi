#!/usr/bin/env bash
# Linux x86_64 版 libfushi_fsrs.so（无头服务端 bundle 随包：bin/../lib/libfushi_fsrs.so；
# 社区维护的 Linux 桌面 copy-if-present 进 bundle/lib/）。
#
# 用法: build_linux_so.sh [target]   缺省 x86_64-unknown-linux-gnu
# 产物: prebuilt/linux-x64/libfushi_fsrs.so（git 忽略，不入库）
# 环境变量 FUSHI_FSRS_FEATURES（可选）：额外的 cargo feature，只给测试用的库——CI 包测试用
# `id_audit` 编（Dart 经桥执行的 SQL 绑了文本 UUID / 写进文本 UUID 就报错，见 src/store/ids.rs `audit`）。
# 随包发布的构建不设它。
# 环境变量 FUSHI_FSRS_ID_AUDIT_VARIANT=1（可选）：另编一份带 `id_audit` 的库到
# prebuilt/linux-x64/id_audit/libfushi_fsrs.so。只给本机的调试构建与测试宿主用（Dart 侧 packages/fushi_srs 的
# kFushiFsrsIdAuditDir：断言开着才去找它），不随包——fushi/linux/CMakeLists.txt 与服务端 bundle 只拷上一级目录里
# 的普通库。tool/bootstrap.sh 设它；发布流水线不设，产物与以前相同。不设它重编时会删掉已有的 id_audit 目录：那份
# 库对应的是上一次的源码，留着会被调试构建优先加载。
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
rm -rf "$OUT_DIR/id_audit"
cp "target/$TARGET/release/libfushi_fsrs.so" "$OUT_DIR/libfushi_fsrs.so"
echo "==> Done: $OUT_DIR/libfushi_fsrs.so ($(wc -c < "$OUT_DIR/libfushi_fsrs.so") bytes)"

if [ "${FUSHI_FSRS_ID_AUDIT_VARIANT:-}" = 1 ]; then
  # 两份共用一个 target 目录、同名产物轮流覆盖：上面那份已经拷走；这一份编完核对它确实带审计。
  audit_features="id_audit${FUSHI_FSRS_FEATURES:+,$FUSHI_FSRS_FEATURES}"
  echo "==> cargo build --release --target $TARGET --features $audit_features (id_audit variant: debug builds / test hosts only, never bundled)"
  cargo build --release --target "$TARGET" --features "$audit_features"
  mkdir -p "$OUT_DIR/id_audit"
  cp "target/$TARGET/release/libfushi_fsrs.so" "$OUT_DIR/id_audit/libfushi_fsrs.so"
  bash "$SCRIPT_DIR/verify_id_audit.sh" "$OUT_DIR/id_audit/libfushi_fsrs.so" present
  echo "==> Done: $OUT_DIR/id_audit/libfushi_fsrs.so ($(wc -c < "$OUT_DIR/id_audit/libfushi_fsrs.so") bytes)"
fi
