#!/usr/bin/env bash
# 产物校验：刚构建出来的 fushi_fsrs 原生库（或静态链进它的 iOS 伞形库 / Runner 主二进制）
# 必须导出 Dart 绑定要 lookup 的**每一个** ffsrs_* 符号。
#
# 构建脚本自己只断言「文件存在」，而 FFI 的失败形态恰恰是「文件在、符号不在」：
# iOS 上 -force_load / dead-strip / strip 任何一环不对，符号会被静默去掉，
# `DynamicLibrary.process().lookup` 抛 ArgumentError → SRS 原生内核判不可用，CI 全绿。
# 期望集直接取自 packages/fushi_srs/lib/src/ffi/fushi_fsrs_bindings.dart 的 lookup 名，
# 所以 lib.rs 与绑定新增符号时这里自动跟上，不用手改清单。
#
# 用法: verify_abi.sh <ELF .so | Mach-O dylib / 可执行文件 / ar 静态库> [nm-binary]
#   nm-binary 缺省 `nm`；Android 交叉产物用 NDK 的 llvm-nm 更稳。
set -euo pipefail

BIN="${1:?usage: verify_abi.sh <binary> [nm-binary]}"
NM="${2:-nm}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINDINGS="$SCRIPT_DIR/../../packages/fushi_srs/lib/src/ffi/fushi_fsrs_bindings.dart"

[[ -f "$BIN" ]] || { echo "::error::artifact not found: $BIN" >&2; exit 1; }
[[ -f "$BINDINGS" ]] || { echo "::error::bindings not found: $BINDINGS" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

grep -oE "'ffsrs_[a-z0-9_]+'" "$BINDINGS" | tr -d "'" | sort -u > "$work/expected.txt"
expected_count="$(wc -l < "$work/expected.txt" | tr -d ' ')"
echo "ffsrs_* symbols looked up by the Dart bindings: $expected_count"
# 扫描规模哨兵：正则被绑定文件的格式改写打断时，期望集会塌成 0 条，「全都导出了」
# 恒真。下界取当前全部 6 个；真删符号是破坏性 ABI 变更（ffsrs_abi_version 同时要升），
# 应当同时改这里。
if [[ "$expected_count" -lt 6 ]]; then
  echo "::error title=ABI symbol extraction collapsed::只从绑定里解析出 $expected_count 个 ffsrs_* 名（<6），正则失效或绑定被大改，不能当通过。" >&2
  exit 1
fi

kind="$(file -b "$BIN")"
case "$kind" in
  ELF*) "$NM" -D --defined-only "$BIN" | awk '{ print $NF }' > "$work/raw.txt" ;;
  Mach-O*) "$NM" -gU "$BIN" | awk '{ print $NF }' | sed 's/^_//' > "$work/raw.txt" ;;
  # 静态库（iOS 伞形 .a）：nm 逐成员输出，成员头行只有一个字段，过滤掉。
  *ar\ archive*) "$NM" -gU "$BIN" 2>/dev/null | awk 'NF >= 2 { print $NF }' | sed 's/^_//' > "$work/raw.txt" ;;
  *) echo "::error::unsupported binary format: $kind" >&2; exit 1 ;;
esac
grep -E '^ffsrs_' "$work/raw.txt" | sort -u > "$work/exported.txt" || true

missing="$(comm -23 "$work/expected.txt" "$work/exported.txt")"
if [[ -n "$missing" ]]; then
  echo "::error title=fushi_fsrs C ABI symbols missing::$BIN 没有导出：$(echo "$missing" | tr '\n' ' ')" >&2
  exit 1
fi
echo "OK: all $expected_count ffsrs_* symbols exported by $BIN"
