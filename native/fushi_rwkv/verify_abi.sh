#!/usr/bin/env bash
# 产物校验：刚构建出来的 fushi_rwkv 原生库（或静态链进它的 iOS 伞形库 / Runner 主二进制）
# 必须导出 C ABI 的**每一个** frwkv_* 符号。与 native/fushi_compute/verify_abi.sh 同一形态。
#
# 构建脚本自己只断言「文件存在」，而 FFI 的失败形态恰恰是「文件在、符号不在」：
# iOS 上 -force_load / dead-strip / strip 任何一环不对，符号会被静默去掉，
# `DynamicLibrary.process().lookup` 抛 ArgumentError → 运行时 FushiRwkvUnavailableError，
# 而构建与只跑 Linux .so 的 CI 全绿。
#
# 期望集 = 两处并集，都自动取、不手维护清单（新增导出函数自动跟上）：
#   * src/ 下所有 `extern "C" fn frwkv_*`（crate 声明的整个 C ABI）；
#   * packages/fushi_rwkv/lib/ 下所有 .dart 里的 'frwkv_xxx' 字面量（Dart 绑定要 lookup 的名字）。
#     Dart 绑定 lookup 了一个 crate 根本没导出的名字，同样会在下面的「缺失」里报出来。
#
# 用法: verify_abi.sh <ELF .so | PE .dll | Mach-O dylib / 可执行文件 / ar 静态库> [nm-binary]
#   nm-binary 缺省 `nm`；Android 交叉产物用 NDK 的 llvm-nm 更稳。
#   PE（Windows .dll）读导出表需要 llvm-readobj / objdump（Git for Windows 自带 objdump）。
set -euo pipefail

BIN="${1:?usage: verify_abi.sh <binary> [nm-binary]}"
NM="${2:-nm}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/src"
BINDINGS_DIR="$SCRIPT_DIR/../../packages/fushi_rwkv/lib"

[[ -f "$BIN" ]] || { echo "::error::artifact not found: $BIN" >&2; exit 1; }
[[ -d "$SRC_DIR" ]] || { echo "::error::crate src dir not found: $SRC_DIR" >&2; exit 1; }
[[ -d "$BINDINGS_DIR" ]] || { echo "::error::bindings dir not found: $BINDINGS_DIR" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# 没有任何命中时 grep 退 1，交给下面的哨兵判。
grep -rhoE --include='*.rs' 'extern "C" fn frwkv_[a-z0-9_]+' "$SRC_DIR" | sed 's/.* fn //' | sort -u > "$work/declared.txt" || true
grep -rhoE --include='*.dart' "[\"']frwkv_[a-z0-9_]+[\"']" "$BINDINGS_DIR" | tr -d "\"'" | sort -u > "$work/looked_up.txt" || true
sort -u "$work/declared.txt" "$work/looked_up.txt" > "$work/expected.txt"
declared_count="$(wc -l < "$work/declared.txt" | tr -d ' ')"
looked_up_count="$(wc -l < "$work/looked_up.txt" | tr -d ' ')"
expected_count="$(wc -l < "$work/expected.txt" | tr -d ' ')"
echo "frwkv_* symbols: $declared_count declared in src/, $looked_up_count looked up by the Dart bindings, $expected_count expected"
# 扫描规模哨兵：正则被格式改写打断时期望集会塌，「全都导出了」恒真。下界 = ABI_VERSION 2 的
# 16 个导出函数（frwkv_abi_version … frwkv_free_bytes，见 src/lib.rs 模块注释）；新增导出会自动进
# 期望集、不必改这里。真删符号是破坏性 ABI 变更（ABI_VERSION 同时要升），应当同时改这里。
if [[ "$declared_count" -lt 16 ]]; then
  echo "::error title=ABI symbol extraction collapsed::只从 src/ 解析出 $declared_count 个 frwkv_* 导出（<16），正则失效或 C ABI 被大改，不能当通过。" >&2
  exit 1
fi
# Dart 侧至少要 lookup 版本握手与错误通道；一个都没扫到说明绑定目录不对或格式被改写。
for must in frwkv_abi_version frwkv_last_error; do
  grep -qx "$must" "$work/looked_up.txt" || {
    echo "::error title=Dart binding scan collapsed::$BINDINGS_DIR 里没扫到 '$must'（共 $looked_up_count 个 frwkv_* 字面量），不能当通过。" >&2
    exit 1
  }
done

kind="$(file -b "$BIN")"
case "$kind" in
  ELF*) "$NM" -D --defined-only "$BIN" | awk '{ print $NF }' > "$work/raw.txt" ;;
  Mach-O*) "$NM" -gU "$BIN" | awk '{ print $NF }' | sed 's/^_//' > "$work/raw.txt" ;;
  # 静态库（iOS 伞形 .a）：nm 逐成员输出，成员头行只有一个字段，过滤掉。nm 的退出码不作数
  # （rustc 的 bitcode 成员 Xcode nm 可能读不了，见 native/fushi_compute/verify_abi.sh）。
  *ar\ archive*) { "$NM" -gU "$BIN" 2>/dev/null || true; } | awk 'NF >= 2 { print $NF }' | sed 's/^_//' > "$work/raw.txt" ;;
  # Windows DLL：读 PE 导出表。llvm-readobj 优先（传的 nm-binary 是 llvm-nm 时取它同目录那个，
  # 例如 NDK 的 toolchains/llvm/prebuilt/windows-x86_64/bin/llvm-nm.exe），否则 objdump -p。
  PE32*)
    nm_name="$(basename "$NM")"
    readobj=""
    if [[ "$nm_name" == *llvm-nm* ]] && [[ -x "$(dirname "$NM")/${nm_name/llvm-nm/llvm-readobj}" ]]; then
      readobj="$(dirname "$NM")/${nm_name/llvm-nm/llvm-readobj}"
    elif command -v llvm-readobj >/dev/null 2>&1; then
      readobj=llvm-readobj
    fi
    if [[ -n "$readobj" ]]; then
      "$readobj" --coff-exports "$BIN" | sed -n 's/^[[:space:]]*Name:[[:space:]]*//p' > "$work/raw.txt"
    elif command -v objdump >/dev/null 2>&1; then
      objdump -p "$BIN" | sed -n 's/^[[:space:]]*\[[[:space:]]*[0-9]*\][[:space:]]*//p' | awk '{ print $NF }' > "$work/raw.txt"
    else
      echo "::error::no llvm-readobj / objdump to read the PE export table of $BIN (pass an llvm-nm whose directory has llvm-readobj)" >&2
      exit 1
    fi
    ;;
  *) echo "::error::unsupported binary format: $kind" >&2; exit 1 ;;
esac
grep -E '^frwkv_' "$work/raw.txt" | sort -u > "$work/exported.txt" || true

missing="$(comm -23 "$work/expected.txt" "$work/exported.txt")"
if [[ -n "$missing" ]]; then
  echo "::error title=fushi_rwkv C ABI symbols missing::$BIN 没有导出：$(echo "$missing" | tr '\n' ' ')" >&2
  exit 1
fi

# Mach-O LINKEDIT 对齐：与 native/fushi_compute/verify_abi.sh 同一条规则（理由见那边注释）——
# 链接 SDK ≥ 27 时未对齐判红（macOS 27 的 dyld 拒绝加载），更旧 SDK 只告警，读不到 SDK 按红。
if [[ "$kind" == Mach-O*64-bit* ]] || [[ "$kind" == Mach-O\ universal* ]]; then
  misaligned="$(otool -l "$BIN" | awk '
    $1 == "cmd" { cmd = $2; pending = ""; next }
    cmd ~ /^LC_(SYMTAB|DYSYMTAB|DYLD_INFO|DYLD_INFO_ONLY|DYLD_CHAINED_FIXUPS|DYLD_EXPORTS_TRIE|FUNCTION_STARTS|DATA_IN_CODE|CODE_SIGNATURE)$/ {
      if (pending != "") {
        if ($2 + 0 > 0 && pendingval % 8 != 0) printf "%s.%s=%d (mod 8 = %d)\n", cmd, pending, pendingval, pendingval % 8
        pending = ""
      }
      if ($1 ~ /off$/ && $1 != "tocoff" && $1 != "modtaboff" && $1 != "extrefsymoff") { pending = $1; pendingval = $2 + 0 }
    }')"
  if [[ -n "$misaligned" ]]; then
    sdk="$(otool -l "$BIN" | awk '
      $1 == "cmd" { cmd = $2; next }
      (cmd == "LC_BUILD_VERSION" || cmd == "LC_VERSION_MIN_MACOSX") && $1 == "sdk" { print $2; exit }')"
    sdk_major="${sdk%%.*}"
    detail="$BIN 的 LINKEDIT 表没有按 8 字节对齐：$(echo "$misaligned" | tr '\n' ' ')（链接 SDK ${sdk:-未知}）"
    if [[ "$sdk_major" =~ ^[0-9]+$ ]] && (( sdk_major < 27 )); then
      echo "::warning title=Mach-O LINKEDIT misaligned (SDK < 27)::${detail}——这个 SDK 链出的二进制 macOS 27 的 dyld 不校验，照常加载；升到 SDK 27 链接时会变成错误。" >&2
    else
      echo "::error title=Mach-O LINKEDIT misaligned::${detail}——macOS 27 的 dyld 会拒绝加载。macOS 产物关掉 cargo strip（CARGO_PROFILE_RELEASE_STRIP=false），改用 /usr/bin/strip -x。" >&2
      exit 1
    fi
  else
    echo "OK: Mach-O LINKEDIT offsets are 8-byte aligned in $BIN"
  fi
fi

echo "OK: all $expected_count frwkv_* symbols exported by $BIN"
