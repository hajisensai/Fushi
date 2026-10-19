#!/usr/bin/env bash
# 产物校验：刚构建出来的 fushi_compute 原生库（或静态链进它的 iOS 伞形库 / Runner 主二进制）
# 必须导出 Dart 绑定要 lookup 的**每一个** ffc_* 符号。
#
# 构建脚本自己只断言「文件存在」，而 FFI 的失败形态恰恰是「文件在、符号不在」：
# iOS 上 -force_load / dead-strip / strip 任何一环不对，符号会被静默去掉，
# `DynamicLibrary.process().lookup` 抛 ArgumentError → 该计算域判不可用、退回 Dart，CI 全绿。
# 期望集**递归**取自 packages/fushi_compute/lib/ 下所有 .dart 里的 'ffc_xxx' 字面量
# （各域绑定分文件放在 lib/src/<域>/ 下），所以新增域符号自动跟上，不用手改清单。
#
# 用法: verify_abi.sh <ELF .so | Mach-O dylib / 可执行文件 / ar 静态库> [nm-binary]
#   nm-binary 缺省 `nm`；Android 交叉产物用 NDK 的 llvm-nm 更稳。
set -euo pipefail

BIN="${1:?usage: verify_abi.sh <binary> [nm-binary]}"
NM="${2:-nm}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINDINGS_DIR="$SCRIPT_DIR/../../packages/fushi_compute/lib"

[[ -f "$BIN" ]] || { echo "::error::artifact not found: $BIN" >&2; exit 1; }
[[ -d "$BINDINGS_DIR" ]] || { echo "::error::bindings dir not found: $BINDINGS_DIR" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# -h：多文件时不带文件名前缀；--include 只扫 .dart。没有任何命中时 grep 退 1，交给下面的哨兵判。
grep -rhoE --include='*.dart' "'ffc_[a-z0-9_]+'" "$BINDINGS_DIR" | tr -d "'" | sort -u > "$work/expected.txt" || true
expected_count="$(wc -l < "$work/expected.txt" | tr -d ' ')"
echo "ffc_* symbols looked up by the Dart bindings: $expected_count"
# 扫描规模哨兵：正则被绑定文件的格式改写打断时，期望集会塌成 0 条，「全都导出了」恒真。
# 下界是「已知必有」的符号数（当前 22：ffc_abi_version、ffc_free_bytes、9 个 ffc_hash_* 与 11 个 ffc_crypto_*）；新增域符号
# 会自动进期望集、不必改这里，但下界应随之调高，免得某个域的绑定整体漏扫还判通过。
# 真删符号是破坏性 ABI 变更（ffc_abi_version 同时要升），应当同时改这里。
if [[ "$expected_count" -lt 22 ]]; then
  echo "::error title=ABI symbol extraction collapsed::只从绑定里解析出 $expected_count 个 ffc_* 名（<22），正则失效或绑定被大改，不能当通过。" >&2
  exit 1
fi

kind="$(file -b "$BIN")"
case "$kind" in
  ELF*) "$NM" -D --defined-only "$BIN" | awk '{ print $NF }' > "$work/raw.txt" ;;
  Mach-O*) "$NM" -gU "$BIN" | awk '{ print $NF }' | sed 's/^_//' > "$work/raw.txt" ;;
  # 静态库（iOS 伞形 .a）：nm 逐成员输出，成员头行只有一个字段，过滤掉。
  # nm 的退出码不作数：rustc 的 compiler_builtins 成员是 bitcode，Xcode 自带 nm 的 LLVM 比 rustc
  # 的旧时读不了（"Unknown attribute kind"）、整体退出 1，pipefail 下脚本会在这里静默挂掉
  # （2026-10-18 在 Mac 上实测）；那些成员里没有 ffc_*，真正的门是下面的「期望符号一个不缺」。
  *ar\ archive*) { "$NM" -gU "$BIN" 2>/dev/null || true; } | awk 'NF >= 2 { print $NF }' | sed 's/^_//' > "$work/raw.txt" ;;
  *) echo "::error::unsupported binary format: $kind" >&2; exit 1 ;;
esac
grep -E '^ffc_' "$work/raw.txt" | sort -u > "$work/exported.txt" || true

missing="$(comm -23 "$work/expected.txt" "$work/exported.txt")"
if [[ -n "$missing" ]]; then
  echo "::error title=fushi_compute C ABI symbols missing::$BIN 没有导出：$(echo "$missing" | tr '\n' ' ')" >&2
  exit 1
fi
echo "OK: all $expected_count ffc_* symbols exported by $BIN"

# ARMv8 AES 产物检查：aes 0.8 在 aarch64 上丢了 `--cfg aes_armv8` 会静默退回软件实现（结果相同，
# A55 实测 655 → 54 MB/s）。src/crypto.rs 的 compile_error! 已在构建期挡住丢 cfg；这里在产物上再
# 核对一次：独立的 libfushi_compute.{so,dylib} 里只有 aes crate 会出 aese/aesd（sha2 / p256 不用），
# 硬件路径在就必有，软件实现一条都没有（2026-10-19 arm64-v8a 实测 288 vs 0）。
# 伞形 .a / Runner 主二进制混着 fushi_p2p 等自带 AES 指令的 crate，计数说明不了 fushi_compute，跳过。
case "$kind" in
  *"ARM aarch64"* | Mach-O*arm64*) arm64=1 ;;
  *) arm64=0 ;;
esac
if [[ "$arm64" == 1 ]]; then
  case "$(basename "$BIN")" in
    libfushi_compute.so | libfushi_compute.dylib)
      nm_name="$(basename "$NM")"
      if [[ "$nm_name" == *llvm-nm* ]]; then
        objdump_bin="$(dirname "$NM")/${nm_name/llvm-nm/llvm-objdump}"
      elif command -v llvm-objdump >/dev/null 2>&1; then
        objdump_bin=llvm-objdump
      else
        objdump_bin=objdump
      fi
      "$objdump_bin" -d --no-show-raw-insn "$BIN" > "$work/disasm.txt" 2>/dev/null || true
      # 反汇编器不认 aarch64（例如 x86 主机上的 GNU objdump）时输出里一条指令都没有：报错，不当通过也不当失败。
      if ! grep -qE '^[[:space:]]*[0-9a-f]+:[[:space:]]' "$work/disasm.txt"; then
        echo "::error title=cannot disassemble::$objdump_bin 反汇编不了 $BIN，无法核对 ARMv8 AES 指令；传 NDK / Xcode 的 llvm-nm（同目录要有 llvm-objdump）。" >&2
        exit 1
      fi
      # GNU/LLVM 语法 `aese v0.16b, v1.16b`；Apple objdump 写成 `aese.16b v1, v0`。
      aes_insns="$(grep -cE '[[:space:]]aes[de][.[:space:]]' "$work/disasm.txt" || true)"
      if [[ "$aes_insns" -eq 0 ]]; then
        echo "::error title=fushi_compute software AES::$BIN 里没有 ARMv8 aese/aesd 指令：构建丢了 --cfg aes_armv8，AES 退回软件实现。" >&2
        exit 1
      fi
      echo "OK: $BIN carries ARMv8 AES instructions ($aes_insns aese/aesd)"
      ;;
    *) echo "note: ARMv8 AES instruction check skipped for $BIN (mixed binary; the compile_error! in src/crypto.rs guards the build)" ;;
  esac
fi
