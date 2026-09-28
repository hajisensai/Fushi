#!/usr/bin/env bash
# 产物校验：刚构建出来的 fushi_p2p 原生库（或静态链进它的 iOS Runner 主二进制）必须
# 导出 Dart 绑定要 lookup 的**每一个** fp2p_* 符号。
#
# 构建脚本自己只断言「文件存在」，而 FFI 的失败形态恰恰是「文件在、符号不在」：
# iOS 上 -force_load / dead-strip / strip 任何一环不对，符号会被静默去掉，
# `DynamicLibrary.process().lookup` 抛 ArgumentError → P2P 能力判不可用，CI 全绿。
# 期望集直接取自 packages/fushi_p2p/lib/src/ffi/fushi_p2p_bindings.dart 的 lookup 名，
# 所以 lib.rs 与绑定新增符号时这里自动跟上，不用手改清单。
#
# 用法: verify_abi.sh <ELF .so | Mach-O dylib/可执行文件> [nm-binary]
#   nm-binary 缺省 `nm`；Android 交叉产物用 NDK 的 llvm-nm 更稳。
set -euo pipefail

BIN="${1:?usage: verify_abi.sh <binary> [nm-binary]}"
NM="${2:-nm}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINDINGS="$SCRIPT_DIR/../../packages/fushi_p2p/lib/src/ffi/fushi_p2p_bindings.dart"

[[ -f "$BIN" ]] || { echo "::error::artifact not found: $BIN" >&2; exit 1; }
[[ -f "$BINDINGS" ]] || { echo "::error::bindings not found: $BINDINGS" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

grep -oE "'fp2p_[a-z0-9_]+'" "$BINDINGS" | tr -d "'" | sort -u > "$work/expected.txt"
expected_count="$(wc -l < "$work/expected.txt" | tr -d ' ')"
echo "fp2p_* symbols looked up by the Dart bindings: $expected_count"
# 扫描规模哨兵：正则被绑定文件的格式改写打断时，期望集会塌成 0 条，「全都导出了」
# 恒真。下界取当前 11 的保守值；真删符号是破坏性 ABI 变更，应当同时改这里。
if [[ "$expected_count" -lt 8 ]]; then
  echo "::error title=ABI symbol extraction collapsed::只从绑定里解析出 $expected_count 个 fp2p_* 名（<8），正则失效或绑定被大改，不能当通过。" >&2
  exit 1
fi

case "$(file -b "$BIN")" in
  ELF*) "$NM" -D --defined-only "$BIN" | awk '{ print $NF }' > "$work/raw.txt" ;;
  Mach-O*) "$NM" -gU "$BIN" | awk '{ print $NF }' | sed 's/^_//' > "$work/raw.txt" ;;
  *) echo "::error::unsupported binary format: $(file -b "$BIN")" >&2; exit 1 ;;
esac
grep -E '^fp2p_' "$work/raw.txt" | sort -u > "$work/exported.txt" || true

missing="$(comm -23 "$work/expected.txt" "$work/exported.txt")"
if [[ -n "$missing" ]]; then
  echo "::error title=fushi_p2p C ABI symbols missing::$BIN 没有导出：$(echo "$missing" | tr '\n' ' ')" >&2
  exit 1
fi
echo "OK: all $expected_count fp2p_* symbols exported by $BIN"
