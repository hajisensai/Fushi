#!/usr/bin/env bash
# iOS 伞形静态库 libfushi_ios_umbrella.a（fushi_p2p + fushi_fsrs + fushi_compute + fushi_web_core
# + fushi_rwkv 合一）+ 给 Runner 链接用的 xcconfig 片段。
#
# 为什么要伞形：每个 Rust staticlib 都带一整份 Rust std，libfushi_p2p.a / libfushi_fsrs.a /
# libfushi_compute.a / libfushi_web_core.a 同时 -force_load 进 Runner 会撞重复符号。合成一个
# crate 编译，std 只有一份，同时导出 fp2p_* / ffsrs_* / ffc_* / fwc_* / frwkv_*（Dart 各方都用
# `DynamicLibrary.process()` 取符号）。
#
# 生成的 xcconfig 定义 FUSHI_IOS_NATIVE_LDFLAGS = -force_load <.a> + rustc 报的系统库。
# fushi/ios 的 Flutter/{Debug,Release}.xcconfig `#include?` 这份 xcconfig，Runner 的
# OTHER_LDFLAGS 用 $(FUSHI_IOS_NATIVE_LDFLAGS)。iOS 上**只**接这一份：fushi_p2p / fushi_fsrs /
# fushi_compute 各自的单独 .a 不能再同时接（同样会撞 std 重复符号）。
#
# 用法: build_ios_staticlib.sh [device|simulator|all]   缺省 all
#   device    : aarch64-apple-ios                        → prebuilt/ios/iphoneos/libfushi_ios_umbrella.a
#   simulator : aarch64-apple-ios-sim + x86_64-apple-ios → prebuilt/ios/iphonesimulator/libfushi_ios_umbrella.a（lipo）
# 前提: rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
#
# 部署目标与 fushi/ios/Runner.xcodeproj 的 IPHONEOS_DEPLOYMENT_TARGET 对齐（15.1）。
set -euo pipefail

WHICH="${1:-all}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/prebuilt/ios"
LIB=libfushi_ios_umbrella.a
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-15.1}"

cd "$SCRIPT_DIR"

# 编一个 target 的 staticlib，把 rustc 报出的「链接方还需要的系统库」写到 $2。
# 与 native/fushi_p2p/build_ios_staticlib.sh 同一套：先 clean 本 crate 保证 rustc 真的重新
# 编译并打印 native-static-libs（依赖 crate 的缓存不受影响）。
build_target() {
  local target="$1" libs_out="$2"
  local log
  log="$(mktemp)"
  cargo clean --release --target "$target" -p fushi_ios_umbrella
  echo "==> cargo rustc --release --lib --target $target --crate-type staticlib (IPHONEOS_DEPLOYMENT_TARGET=$IPHONEOS_DEPLOYMENT_TARGET)"
  # --color never：CI 的 CARGO_TERM_COLOR=always 会让 note 行带 ANSI 转义，污染库名。
  cargo rustc --locked --color never --release --lib --target "$target" --crate-type staticlib \
    -- --print native-static-libs 2>&1 | tee "$log"
  local libs
  libs="$(sed -n 's/.*native-static-libs: //p' "$log" | tail -n 1)"
  rm -f "$log"
  if [[ -z "$libs" ]]; then
    echo "rustc did not report native-static-libs for $target" >&2
    exit 1
  fi
  # 这串原样进 OTHER_LDFLAGS：只允许 -l<name> / -framework <name>。
  local prev="" tok
  for tok in $libs; do
    if [[ "$prev" == "-framework" ]]; then
      [[ "$tok" =~ ^[A-Za-z0-9_]+$ ]] || { echo "bad framework name in native-static-libs: $tok" >&2; exit 1; }
    elif [[ "$tok" != "-framework" && ! "$tok" =~ ^-l[A-Za-z0-9_+.-]+$ ]]; then
      echo "unexpected token in native-static-libs: $(printf '%q' "$tok")" >&2
      exit 1
    fi
    prev="$tok"
  done
  printf '%s\n' "$libs" > "$libs_out"
  [[ -f "target/$target/release/$LIB" ]] || { echo "missing target/$target/release/$LIB" >&2; exit 1; }
}

# 归档必须同时导出各 Dart 绑定 lookup 的全部符号（期望集取自绑定的字面量）。
# 每项 = 前缀:规模哨兵下界:绑定文件或目录（目录递归扫其中所有 .dart，fushi_compute 各域分文件）。
# 下界与各 crate 自己的 verify_abi.sh 保持一致。
verify_archive() {
  local archive="$1" entry prefix rest min bindings expected exported missing excl
  # nm 的退出码不作数：rustc 的 compiler_builtins 成员是 bitcode，Xcode 自带 nm 的 LLVM 比
  # rustc 的旧时读不了（"Unknown attribute kind"）、整体退出 1，pipefail 下脚本会静默挂掉。
  # 那些成员里没有 fp2p_* / ffsrs_* / ffc_*；真正的门是下面的「期望符号一个不缺」。
  exported="$({ nm -gU "$archive" 2>/dev/null || true; } | awk 'NF >= 2 { print $NF }' | sed 's/^_//' | sort -u)"
  for entry in "fp2p:6:$SCRIPT_DIR/../../packages/fushi_p2p/lib/src/ffi/fushi_p2p_bindings.dart" \
               "ffsrs:6:$SCRIPT_DIR/../../packages/fushi_srs/lib/src/ffi/fushi_fsrs_bindings.dart" \
               "ffc:2:$SCRIPT_DIR/../../packages/fushi_compute/lib" \
               "fwc:6:$SCRIPT_DIR/../../packages/fushi_web_core/lib/src/ffi/fushi_web_core_bindings.dart" \
               "frwkv:2:$SCRIPT_DIR/../../packages/fushi_rwkv/lib" \
               "ffm:7:$SCRIPT_DIR/../../packages/fushi_music/lib" \
               "fcorp:12:$SCRIPT_DIR/../../packages/fushi_corpus/lib"; do
    prefix="${entry%%:*}"
    rest="${entry#*:}"
    min="${rest%%:*}"
    bindings="${rest#*:}"
    # fushi_music 在伞形库里按 default-features = false 编（不带 plugin 特性：在线音源插件的
    # JS 运行时，iOS 合规不上），期望集排除插件绑定目录 lib/src/plugin/（同 verify_abi.sh --no-plugin）。
    excl=()
    [[ "$prefix" == ffm ]] && excl=(--exclude-dir=plugin)
    expected="$({ grep -rhoE --include='*.dart' ${excl[@]+"${excl[@]}"} "'${prefix}_[a-z0-9_]+'" "$bindings" || true; } | tr -d "'" | sort -u)"
    [[ "$(echo "$expected" | grep -c .)" -ge "$min" ]] || { echo "::error::expected ${prefix}_* set collapsed (<$min)" >&2; exit 1; }
    missing="$(comm -23 <(echo "$expected") <(echo "$exported"))"
    if [[ -n "$missing" ]]; then
      echo "::error title=iOS umbrella symbols missing::$archive 没有导出：$(echo "$missing" | tr '\n' ' ')" >&2
      exit 1
    fi
    echo "OK: $archive exports all $(echo "$expected" | grep -c .) ${prefix}_* symbols"
  done
}

build_device() {
  local dir="$OUT_DIR/iphoneos"
  mkdir -p "$dir"
  build_target aarch64-apple-ios "$dir/native-static-libs.txt"
  cp "target/aarch64-apple-ios/release/$LIB" "$dir/$LIB"
  lipo -info "$dir/$LIB"
  verify_archive "$dir/$LIB"
}

build_simulator() {
  local dir="$OUT_DIR/iphonesimulator"
  mkdir -p "$dir"
  build_target aarch64-apple-ios-sim "$dir/.libs.arm64"
  build_target x86_64-apple-ios "$dir/.libs.x86_64"
  lipo -create \
    "target/aarch64-apple-ios-sim/release/$LIB" \
    "target/x86_64-apple-ios/release/$LIB" \
    -output "$dir/$LIB"
  echo "$(cat "$dir/.libs.arm64") $(cat "$dir/.libs.x86_64")" > "$dir/native-static-libs.txt"
  rm -f "$dir/.libs.arm64" "$dir/.libs.x86_64"
  lipo -info "$dir/$LIB"
}

case "$WHICH" in
  device) build_device ;;
  simulator) build_simulator ;;
  all) build_device; build_simulator ;;
  *) echo "usage: build_ios_staticlib.sh [device|simulator|all]" >&2; exit 2 ;;
esac

# xcconfig 按「磁盘上实际存在的切片」生成（先编 simulator 再单编 device 时两个 SDK 都还能链接）。
xc="$OUT_DIR/fushi_ios_umbrella.xcconfig"
{
  echo "// Generated by native/fushi_ios_umbrella/build_ios_staticlib.sh - do not edit (git-ignored)."
  echo "// Included by fushi/ios/Flutter/{Debug,Release}.xcconfig; Runner OTHER_LDFLAGS uses \$(FUSHI_IOS_NATIVE_LDFLAGS)."
  echo 'FUSHI_IOS_NATIVE_DIR = $(PROJECT_DIR)/../../native/fushi_ios_umbrella/prebuilt/ios'
  for sdk in iphoneos iphonesimulator; do
    [[ -f "$OUT_DIR/$sdk/$LIB" ]] || continue
    echo "FUSHI_IOS_NATIVE_LDFLAGS[sdk=${sdk}*] = -force_load \"\$(FUSHI_IOS_NATIVE_DIR)/$sdk/$LIB\" $(cat "$OUT_DIR/$sdk/native-static-libs.txt")"
  done
} > "$xc"
echo "==> $xc"
cat "$xc"
