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

echo "OK: all $expected_count frwkv_* symbols exported by $BIN"
