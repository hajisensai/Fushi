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
# Mach-O LINKEDIT 对齐：64 位 Mach-O 的 LINKEDIT 各表（符号表、字符串表、间接符号表、重定位、
# chained fixups / 导出 trie / 代码签名等）起点必须按 8 字节对齐。rust-objcopy（cargo 的
# strip = true / "debuginfo" 在 Apple 目标上调用它）重排 LINKEDIT 时不补齐：间接符号表
# 项数（每项 4 字节）为奇数时，紧跟其后的字符串表只对齐到 4。用 SDK 27 及以上链接的
# 二进制，macOS 27 的 dyld 会以「mis-aligned LINKEDIT string pool」拒绝加载；SDK 更旧的
# 不校验，所以 CI runner 上 dlopen 照样成功——只有这条静态检查与 runner 系统 / SDK 无关。
# Apple 的 /usr/bin/strip 和 ld 的输出都已补齐。静态库（ar）的成员会被重新链接，不查。
if [[ "$(file -b "$BIN")" == Mach-O*64-bit* ]] || { [[ "$(file -b "$BIN")" == Mach-O\ universal* ]]; }; then
  misaligned="$(otool -l "$BIN" | awk '
    $1 == "cmd" { cmd = $2; pending = ""; next }
    # 「<名>off <偏移>」后面紧跟它的大小 / 个数；大小为 0 的表不占空间，不查。
    cmd ~ /^LC_(SYMTAB|DYSYMTAB|DYLD_INFO|DYLD_INFO_ONLY|DYLD_CHAINED_FIXUPS|DYLD_EXPORTS_TRIE|FUNCTION_STARTS|DATA_IN_CODE|CODE_SIGNATURE)$/ {
      if (pending != "") {
        if ($2 + 0 > 0 && pendingval % 8 != 0) printf "%s.%s=%d (mod 8 = %d)\n", cmd, pending, pendingval, pendingval % 8
        pending = ""
      }
      if ($1 ~ /off$/ && $1 != "tocoff" && $1 != "modtaboff" && $1 != "extrefsymoff") { pending = $1; pendingval = $2 + 0 }
    }')"
  if [[ -n "$misaligned" ]]; then
    echo "::error title=Mach-O LINKEDIT misaligned::$BIN 的 LINKEDIT 表没有按 8 字节对齐：$(echo "$misaligned" | tr '\n' ' ')——macOS 27 的 dyld 会拒绝加载（mis-aligned LINKEDIT string pool）。多半是链接后又被 strip 工具改写过（rust-objcopy 与 runner 上的 /usr/bin/strip 都不补齐）：关掉 cargo strip（CARGO_PROFILE_RELEASE_STRIP=false），本地符号交给链接器 -Wl,-x，不要再事后 strip。" >&2
    exit 1
  fi
  echo "OK: Mach-O LINKEDIT offsets are 8-byte aligned in $BIN"
fi

echo "OK: all $expected_count fp2p_* symbols exported by $BIN"
