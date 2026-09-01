#!/usr/bin/env bash
# 产物校验：刚构建出来的 fushi_torrent bridge 共享库，必须把 C ABI 头文件里声明的
# **每一个** HT_EXPORT 符号都真的导出到动态符号表。
#
# 为什么这一层单独存在：build_windows_dll.ps1 / build_android_so.sh 的自检只到
# 「文件存在」。而 FFI 的失败形态恰恰是「文件在、符号不在」——
# `DynamicLibrary.lookup` 要等用户装上新包、点到那个功能才抛，CI 全绿。
# 纯文本层的头文件 <-> Dart 绑定漂移由
# fushi/test/media/torrent/torrent_ffi_bindings_parity_guard_test.dart 兜底；
# 这里补的是「头文件 <-> 真实二进制」那一段，只有真编出产物的地方才做得到。
#
# 用法: verify_torrent_abi.sh <so-path> <nm-binary>
#   nm-binary 可以是 host `nm`，也可以是 NDK 的 llvm-nm（交叉产物用后者更稳）。
set -euo pipefail

SO="${1:?usage: verify_torrent_abi.sh <so-path> <nm-binary>}"
NM="${2:?usage: verify_torrent_abi.sh <so-path> <nm-binary>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HEADER="$REPO_ROOT/native/fushi_torrent/fushi_torrent_include/fushi_torrent.h"

[[ -f "$SO" ]] || { echo "::error::artifact not found: $SO" >&2; exit 1; }
[[ -f "$HEADER" ]] || { echo "::error::header not found: $HEADER" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# 期望集：头文件里 `HT_EXPORT <ret> ht_xxx(` 的函数名。
grep -oE 'HT_EXPORT[^;(]*\bht_[a-z0-9_]+[[:space:]]*\(' "$HEADER" \
  | grep -oE '\bht_[a-z0-9_]+' | sort -u > "$work/expected.txt"

expected_count="$(wc -l < "$work/expected.txt" | tr -d ' ')"
echo "C ABI symbols declared in fushi_torrent.h: $expected_count"

# 扫描规模哨兵：正则被格式化/改写打断时，期望集会静默塌成 0 条，于是「全都导出了」
# 恒真、这道校验变成空转。下界取当前 37 的保守值；真删符号是破坏性 ABI 变更，
# 应当同时改这里，而不是让哨兵默默放行。
if [[ "$expected_count" -lt 30 ]]; then
  echo "::error title=ABI symbol extraction collapsed::只从 $HEADER 解析出 $expected_count 个 HT_EXPORT 符号（<30）。要么头文件被大改，要么本脚本的正则失效了 —— 两种都不能当通过。" >&2
  exit 1
fi

# 实际集：动态符号表里已定义的 ht_* 符号。
"$NM" -D --defined-only "$SO" > "$work/nm.txt"
awk '{ print $NF }' "$work/nm.txt" | grep -E '^ht_[a-z0-9_]+$' | sort -u > "$work/actual.txt" || true

actual_count="$(wc -l < "$work/actual.txt" | tr -d ' ')"
echo "ht_* symbols exported by $(basename "$SO"): $actual_count"

comm -23 "$work/expected.txt" "$work/actual.txt" > "$work/missing.txt"
if [[ -s "$work/missing.txt" ]]; then
  echo "::error title=C ABI symbols missing from artifact::头文件声明了但产物没导出的符号：" >&2
  sed 's/^/  - /' "$work/missing.txt" >&2
  exit 1
fi

echo "OK: all $expected_count declared C ABI symbols are exported."
