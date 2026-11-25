#!/usr/bin/env bash
# 对一个 iOS .app 里的每个 Mach-O（主程序、Frameworks/*.framework、PlugIns/*.appex、散落 dylib）
# 做 `strip -x`：只去本地符号（= Xcode 的 STRIP_STYLE=non-global），导出符号一个不动。
#
# BUG-4656：`flutter build ios --release --no-codesign` 走 Xcode 的 build 动作，
# DEPLOYMENT_POSTPROCESSING=NO，Runner 工程上的 STRIP_STYLE 不执行；CocoaPods 嵌入的预编译
# framework 也不 strip。未签名 IPA（GitHub Release 侧载包）因此带着约 27 MB 本地符号表；TestFlight 的 archive 只 strip 了 Runner，嵌入的预编译 framework 仍带约 10 MB。
# 崩溃符号化靠 CI 单独上传的 dSYM，本地符号表对包没有用处。
#
# 失败口径：strip 前后每个二进制的「已定义全局符号」集合必须完全相同；Runner 里 Dart FFI 要
# lookup 的 C 接口前缀（fp2p_/ffsrs_/ffc_/fcp_/fwc_/frwkv_/ffm_/fcorp_）计数必须不变且 > 0。
# 任何一条不满足就退出非零，让出包步骤失败。
#
# 用法: ios_strip_local_symbols.sh <path/to/Runner.app>
set -euo pipefail

APP="${1:?usage: ios_strip_local_symbols.sh <Runner.app>}"
[[ -d "$APP" ]] || { echo "::error::app bundle not found: $APP" >&2; exit 1; }

STRIP=(xcrun strip)
NM=(xcrun nm)
FFI_PREFIX_RE='^_(fp2p|ffsrs|ffc|fcp|fwc|frwkv|ffm|fcorp)_'

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

exports_of() { "${NM[@]}" -gUj "$1" | LC_ALL=C sort -u; }
size_of() { stat -f %z "$1"; }

total_before=0
total_after=0
count=0
runner_ffi_before=-1
# flutter_assets 里是几千个资源文件，没有 Mach-O，跳过省掉逐个 `file`。
while IFS= read -r -d '' bin; do
  case "$(file -b "$bin")" in
    Mach-O*) ;;
    *) continue ;;
  esac
  rel="${bin#"$APP"/}"
  exports_of "$bin" > "$work/before.txt"
  before_size="$(size_of "$bin")"
  if [[ "$rel" == "Runner" ]]; then
    runner_ffi_before="$(grep -cE "$FFI_PREFIX_RE" "$work/before.txt" || true)"
  fi
  "${STRIP[@]}" -x "$bin" 2> "$work/strip.err" || {
    cat "$work/strip.err" >&2
    echo "::error title=strip -x failed::$rel" >&2
    exit 1
  }
  exports_of "$bin" > "$work/after.txt"
  after_size="$(size_of "$bin")"
  if ! cmp -s "$work/before.txt" "$work/after.txt"; then
    echo "::error title=strip changed exported symbols::$rel（导出符号集合在 strip -x 前后不同）" >&2
    diff "$work/before.txt" "$work/after.txt" | head -40 >&2 || true
    exit 1
  fi
  if [[ "$rel" == "Runner" ]]; then
    runner_ffi_after="$(grep -cE "$FFI_PREFIX_RE" "$work/after.txt" || true)"
    echo "Runner FFI exports (fp2p_/ffsrs_/ffc_/fcp_/fwc_/frwkv_/ffm_/fcorp_): before=$runner_ffi_before after=$runner_ffi_after"
    if [[ "$runner_ffi_before" -le 0 || "$runner_ffi_after" -ne "$runner_ffi_before" ]]; then
      echo "::error title=Runner FFI exports changed::strip 前 $runner_ffi_before 个、后 $runner_ffi_after 个" >&2
      exit 1
    fi
  fi
  printf '%10d -> %10d  %s\n' "$before_size" "$after_size" "$rel"
  total_before=$((total_before + before_size))
  total_after=$((total_after + after_size))
  count=$((count + 1))
done < <(find "$APP" -name flutter_assets -prune -o -type f -print0)

if [[ "$runner_ffi_before" -lt 0 ]]; then
  echo "::error title=Runner not found::$APP/Runner 不是 Mach-O 或不存在" >&2
  exit 1
fi
echo "strip -x: $count Mach-O, $total_before -> $total_after bytes (-$((total_before - total_after)))"
