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
# srs.db 句柄（ffsrs_store_*）的 lookup 在 SrsCoreBindings 里。
STORE_BINDINGS="$SCRIPT_DIR/../../packages/fushi_srs/lib/src/store/srs_core.dart"

[[ -f "$BIN" ]] || { echo "::error::artifact not found: $BIN" >&2; exit 1; }
[[ -f "$BINDINGS" ]] || { echo "::error::bindings not found: $BINDINGS" >&2; exit 1; }
[[ -f "$STORE_BINDINGS" ]] || { echo "::error::bindings not found: $STORE_BINDINGS" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

grep -ohE "'ffsrs_[a-z0-9_]+'" "$BINDINGS" "$STORE_BINDINGS" | tr -d "'" | sort -u > "$work/expected.txt"
expected_count="$(wc -l < "$work/expected.txt" | tr -d ' ')"
echo "ffsrs_* symbols looked up by the Dart bindings: $expected_count"
# 扫描规模哨兵：正则被绑定文件的格式改写打断时，期望集会塌成 0 条，「全都导出了」
# 恒真。下界取当前全部 37 个：ABI 4（2026-10-30）把 Anki 搜索语料搬进 srs.db 的常驻浏览会话（store/browse.rs，
# 走 ffsrs_store_* 命令），删掉了 9 个 ffsrs_search_corpus_* / ffsrs_search_chunk_* 语料与分块符号（原 46 个）。
# 真删符号是破坏性 ABI 变更（ffsrs_abi_version 同时要升），应当同时改这里。
if [[ "$expected_count" -lt 37 ]]; then
  echo "::error title=ABI symbol extraction collapsed::只从绑定里解析出 $expected_count 个 ffsrs_* 名（<37），正则失效或绑定被大改，不能当通过。" >&2
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
# Mach-O LINKEDIT 对齐：按 dyld 的真实规则判（macOS 27.2 的 dyld-27102 反汇编所得，
# mach_o::Header 的 LINKEDIT 布局校验；开源的 dyld-1378 还没有字符串表这条）：
#   * 64 位 Mach-O 的每块非空 LINKEDIT 内容（符号表、字符串表、间接符号表、重定位、
#     dyld info、chained fixups、导出 trie、function starts 等）起点按 8 字节对齐（32 位按 4）；
#     代码签名另要 16 字节对齐。
#   * 是否「拒绝加载」看二进制自己记录的链接 SDK（LC_BUILD_VERSION / LC_VERSION_MIN_* 的 sdk，
#     dyld 的 enforcement epoch），与运行它的系统无关：字符串表（string pool）从 SDK 27
#     （fall 2026）起才校验——不满足即「mis-aligned LINKEDIT string pool」；其它内容从
#     SDK 10.14 / iOS 12（fall 2018）起校验；代码签名从 SDK 10.11 / iOS 9 起校验。
#     SDK 更旧、dyld 不校验的只告警（换 SDK 27 链接就会变成错误）；读不到 SDK 按校验处理。
# 典型来源：rustc 的 -C strip（rust-objcopy 重排 LINKEDIT，字符串表紧跟奇数项的间接符号表时
# 只对齐到 4），见 build_macos_dylib.sh。静态库（ar）的成员会被重新链接，不查。
macho_kind="$(file -b "$BIN")"
if [[ "$macho_kind" == Mach-O* ]]; then
  if [[ "$macho_kind" == *64-bit* || "$macho_kind" == Mach-O\ universal* ]]; then macho_align=8; else macho_align=4; fi
  linkedit_report="$(otool -l "$BIN" | awk -v align="$macho_align" '
    function ver(s,   a) { if (s !~ /^[0-9]+(\.[0-9]+)*$/) return -1; split(s, a, "."); return a[1] * 100 + a[2] }
    function add(name, off, size) { if (size + 0 > 0) { n++; bname[n] = name; boff[n] = off + 0 } }
    function flush(   i, sdkv, legacy, sev, why) {
      if (n == 0 && !started) return
      sdkv = ver(sdk)
      # macOS 与 iOS 系的 epoch 版本号不同：fall 2015 / 2018 = 10.11 / 10.14（macOS）、9 / 12（iOS 系）。
      if (mac) { cs_from = 1011; content_from = 1014 } else { cs_from = 900; content_from = 1200 }
      pool_from = 2700
      for (i = 1; i <= n; i++) {
        if (bname[i] == "code signature" && boff[i] % 16 != 0) {
          sev = (sdkv < 0 || sdkv >= cs_from) ? "ERROR" : "WARN"
          printf "%s %s%s off=%d (mod 16 = %d)\n", sev, slice, bname[i], boff[i], boff[i] % 16
        }
        if (boff[i] % align != 0) {
          from = (bname[i] == "symbol strings") ? pool_from : content_from
          sev = (sdkv < 0 || sdkv >= from) ? "ERROR" : "WARN"
          printf "%s %s%s off=%d (mod %d = %d), SDK %s\n", sev, slice, bname[i], boff[i], align, boff[i] % align, (sdk == "" ? "unknown" : sdk)
        }
      }
      n = 0; sdk = ""; mac = 1; started = 0
    }
    BEGIN { n = 0; mac = 1 }
    # otool 每个切片（universal 的每个架构）以「<路径> (architecture X):」开头，单架构只有「<路径>:」。
    /^[^ \t].*:$/ && !/^Load command/ { flush(); slice = ($0 ~ /\(architecture /) ? $0 " " : ""; started = 1; next }
    $1 == "cmd" { cmd = $2; next }
    cmd == "LC_BUILD_VERSION" && $1 == "platform" { mac = ($2 == "1" || $2 == "MACOS") }
    cmd ~ /^LC_VERSION_MIN_(IPHONEOS|TVOS|WATCHOS)$/ { mac = 0 }
    (cmd == "LC_BUILD_VERSION" || cmd ~ /^LC_VERSION_MIN_/) && $1 == "sdk" { sdk = $2 }
    cmd == "LC_SYMTAB" && $1 == "symoff" { so = $2 } cmd == "LC_SYMTAB" && $1 == "nsyms" { add("symbol table", so, $2) }
    cmd == "LC_SYMTAB" && $1 == "stroff" { st = $2 } cmd == "LC_SYMTAB" && $1 == "strsize" { add("symbol strings", st, $2) }
    cmd == "LC_DYSYMTAB" && $1 == "indirectsymoff" { io = $2 } cmd == "LC_DYSYMTAB" && $1 == "nindirectsyms" { add("indirect symbol table", io, $2) }
    cmd == "LC_DYSYMTAB" && $1 == "extreloff" { eo = $2 } cmd == "LC_DYSYMTAB" && $1 == "nextrel" { add("external relocations", eo, $2) }
    cmd == "LC_DYSYMTAB" && $1 == "locreloff" { lo = $2 } cmd == "LC_DYSYMTAB" && $1 == "nlocrel" { add("local relocations", lo, $2) }
    cmd ~ /^LC_DYLD_INFO/ && $1 ~ /_off$/ { po = $2; pn = $1; next }
    cmd ~ /^LC_DYLD_INFO/ && $1 ~ /_size$/ { add(pn, po, $2) }
    $1 == "dataoff" { po = $2 } $1 == "datasize" { add(cmd == "LC_CODE_SIGNATURE" ? "code signature" : cmd, po, $2) }
    END { flush() }')"
  linkedit_errors="$(printf '%s\n' "$linkedit_report" | sed -n 's/^ERROR //p')"
  linkedit_warnings="$(printf '%s\n' "$linkedit_report" | sed -n 's/^WARN //p')"
  if [[ -n "$linkedit_warnings" ]]; then
    echo "::warning title=Mach-O LINKEDIT misaligned (not enforced for this SDK)::$BIN：$(echo "$linkedit_warnings" | tr '\n' ';')——链接 SDK 旧，dyld 不校验、照常加载；用更新的 SDK 链接时会变成加载失败。" >&2
  fi
  if [[ -n "$linkedit_errors" ]]; then
    echo "::error title=Mach-O LINKEDIT misaligned::$BIN：$(echo "$linkedit_errors" | tr '\n' ';')——dyld 会拒绝加载（字符串表即「mis-aligned LINKEDIT string pool」）。macOS 产物别让 rustc strip（cargo rustc 末尾 -C strip=none，改用 /usr/bin/strip -x），见 build_macos_dylib.sh。" >&2
    exit 1
  fi
  echo "OK: no LINKEDIT misalignment that dyld enforces for the SDK $BIN was linked with"
fi

echo "OK: all $expected_count ffsrs_* symbols exported by $BIN"
