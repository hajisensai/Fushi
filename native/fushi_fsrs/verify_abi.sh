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
# 恒真。下界取当前全部 19 个（7 个排程 / zstd + 10 个 Anki 搜索 + 2 个卡片历史）；真删符号是破坏性 ABI
# 变更（ffsrs_abi_version 同时要升），应当同时改这里。
if [[ "$expected_count" -lt 19 ]]; then
  echo "::error title=ABI symbol extraction collapsed::只从绑定里解析出 $expected_count 个 ffsrs_* 名（<19），正则失效或绑定被大改，不能当通过。" >&2
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
# Mach-O LINKEDIT 对齐：64 位 Mach-O 的 LINKEDIT 各表（符号表、字符串表、间接符号表、重定位、
# chained fixups / 导出 trie / 代码签名等）起点必须按 8 字节对齐。rust-objcopy（cargo 的
# strip = true / "debuginfo" 在 Apple 目标上调用它）重排 LINKEDIT 时不补齐：间接符号表
# 项数（每项 4 字节）为奇数时，紧跟其后的字符串表只对齐到 4。用 SDK 27 及以上链接的
# 二进制，macOS 27 的 dyld 会以「mis-aligned LINKEDIT string pool」拒绝加载；SDK 更旧的
# 不校验，所以 CI runner 上 dlopen 照样成功——这条静态检查读出二进制自己记录的链接 SDK，
# 与 runner 系统无关地按 dyld 的真实规则判：SDK ≥ 27 时未对齐判红；更旧的 SDK 只告警
# （dyld 不校验，判红就是把 runner 的 SDK 当成用户机器上的规则）。读不到 SDK 按红处理。
# Xcode 27 的 /usr/bin/strip 会补齐（#2329 实测）；macos-latest runner 的 strip 与 ld 都
# 不保证补齐（2026-10-19 develop 出包实测 fushi_fsrs stroff mod 8 = 4，所以不能只靠
# 「strip 过就一定对齐」）。静态库（ar）的成员会被重新链接，不查。
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
    # 链接 SDK：LC_BUILD_VERSION 的 sdk 字段（老格式 LC_VERSION_MIN_MACOSX 也带 sdk），取主版本号。
    sdk="$(otool -l "$BIN" | awk '
      $1 == "cmd" { cmd = $2; next }
      (cmd == "LC_BUILD_VERSION" || cmd == "LC_VERSION_MIN_MACOSX") && $1 == "sdk" { print $2; exit }')"
    sdk_major="${sdk%%.*}"
    detail="$BIN 的 LINKEDIT 表没有按 8 字节对齐：$(echo "$misaligned" | tr '\n' ' ')（链接 SDK ${sdk:-未知}）"
    if [[ "$sdk_major" =~ ^[0-9]+$ ]] && (( sdk_major < 27 )); then
      echo "::warning title=Mach-O LINKEDIT misaligned (SDK < 27)::${detail}——这个 SDK 链出的二进制 macOS 27 的 dyld 不校验，照常加载；升到 SDK 27 链接时会变成错误，那时要换成会补齐的 strip（Xcode 27 的 /usr/bin/strip）。" >&2
    else
      echo "::error title=Mach-O LINKEDIT misaligned::${detail}——macOS 27 的 dyld 会拒绝加载（mis-aligned LINKEDIT string pool）。多半是 rust-objcopy strip 过：macOS 产物关掉 cargo strip（CARGO_PROFILE_RELEASE_STRIP=false），改用 /usr/bin/strip -x，并确认产物对齐。" >&2
      exit 1
    fi
  else
    echo "OK: Mach-O LINKEDIT offsets are 8-byte aligned in $BIN"
  fi
fi

echo "OK: all $expected_count ffsrs_* symbols exported by $BIN"
