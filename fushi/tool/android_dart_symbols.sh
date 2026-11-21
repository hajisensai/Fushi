#!/usr/bin/env bash
# Android 发布包的 Dart 调试信息（BUG-4955）。
#
# Android 上 gen_snapshot 不 strip（flutter_tools base/build.dart：「let AGP handle stripping」），
# `build/app/intermediates/flutter/release/<abi>/app.so` 是带 .symtab + .debug_info + .debug_line
# 的完整 ELF；AGP 打包时把它 strip 成 APK 里的 lib/<abi>/libapp.so，GNU build-id 不变。
# 不留这份未 strip 的 ELF，ANR / tombstone 栈里 `base.apk (offset …) (???)` 的 pc 就对不上源码
# （反馈 ICF67eBY57：十几次 ANR 全是 libapp.so 的裸 pc）。
#
# 不用 --split-debug-info：它连带 --dwarf-stack-traces，把 app 内的 Dart 栈改成 DWARF 形式，
# 诊断日志的 ui_activity_probe 调用点归因（who= / fcb=）与反馈里的符号化栈全部退化。这里只是
# 把本来就生成的未 strip ELF 存下来，运行时零改动。
#
# 用法（working-directory: fushi）：
#   bash tool/android_dart_symbols.sh stash <flutter target-platform>
#       每次 `flutter build apk --release --target-platform X` 之后立刻调用：flutter assemble
#       换 target-platform 重编时会清掉上一次的输出，所以逐 ABI 出包要逐次收。
#   bash tool/android_dart_symbols.sh verify
#       对 build/app/outputs/flutter-apk/*-release.apk 里每个 lib/<abi>/libapp.so，核对收到的
#       ELF 存在、build-id 与包里一致、确实带 .symtab 与 .debug_line。
set -euo pipefail

INTERMEDIATE_DIR=build/app/intermediates/flutter/release
OUT_DIR=build/android-dart-symbols
APK_DIR=build/app/outputs/flutter-apk

# flutter --target-platform → Android ABI 目录名（与 FlutterPluginConstants.PLATFORM_ARCH_MAP 一致）。
abi_of() {
  case "$1" in
    android-arm) echo armeabi-v7a ;;
    android-arm64) echo arm64-v8a ;;
    android-x64) echo x86_64 ;;
    *)
      echo "::error title=Android Dart symbols::unknown target-platform '$1'" >&2
      return 1
      ;;
  esac
}

# 读不出（不是 ELF / 没有 build-id note）时输出空串，由调用方按「不一致」报错。
build_id_of() {
  { readelf -n "$1" 2>/dev/null || true; } | sed -n 's/^ *Build ID: *\([0-9a-f]*\)$/\1/p' | head -n 1
}

stash() {
  local platform="$1"
  local abi
  abi="$(abi_of "$platform")"
  local src="$INTERMEDIATE_DIR/$abi/app.so"
  if [ ! -f "$src" ]; then
    echo "::error title=Android Dart symbols missing::$src not found after building $platform (Flutter gradle plugin intermediate layout changed?)"
    return 1
  fi
  mkdir -p "$OUT_DIR/$abi"
  cp "$src" "$OUT_DIR/$abi/app.so"
  echo "stashed $src -> $OUT_DIR/$abi/app.so (build-id $(build_id_of "$OUT_DIR/$abi/app.so"))"
}

verify() {
  shopt -s nullglob
  local apks=("$APK_DIR"/*-release.apk)
  if [ "${#apks[@]}" -eq 0 ]; then
    echo "::error title=Android Dart symbols::no *-release.apk in $APK_DIR"
    return 1
  fi
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  local failed=0
  local apk entry abi packed stashed want got
  for apk in "${apks[@]}"; do
    while IFS= read -r entry; do
      abi="$(echo "$entry" | cut -d/ -f2)"
      packed="$tmp/$abi-libapp.so"
      unzip -p "$apk" "$entry" > "$packed"
      stashed="$OUT_DIR/$abi/app.so"
      want="$(build_id_of "$packed")"
      if [ ! -f "$stashed" ]; then
        echo "::error title=Android Dart symbols missing::$apk ships $entry but $stashed was not stashed"
        failed=1
        continue
      fi
      got="$(build_id_of "$stashed")"
      if [ -z "$want" ] || [ "$want" != "$got" ]; then
        echo "::error title=Android Dart symbols mismatch::$apk $entry build-id '$want' != stashed $stashed build-id '$got'"
        failed=1
        continue
      fi
      for section in .symtab .debug_line; do
        if ! { readelf -S -W "$stashed" 2>/dev/null || true; } | grep -q " ${section} "; then
          echo "::error title=Android Dart symbols stripped::$stashed has no $section"
          failed=1
        fi
      done
      echo "ok: $apk $entry build-id $want"
    done < <(unzip -Z1 "$apk" | grep -E '^lib/[^/]+/libapp\.so$')
  done
  return "$failed"
}

case "${1:-}" in
  stash)
    stash "${2:?target-platform required}"
    ;;
  verify)
    verify
    ;;
  *)
    echo "usage: $0 stash <target-platform> | verify" >&2
    exit 2
    ;;
esac
