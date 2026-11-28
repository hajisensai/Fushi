#!/usr/bin/env bash
# Xcode 构建阶段「Check native libraries (iOS umbrella)」：登记表 native/crates.json 里 iOS 上
# `required: always`、经伞形库 native/fushi_ios_umbrella 链入的 crate（tool/native_crates.py ios-checks
# 列出 crate 与它的 ABI 握手符号；本脚本不列 crate 名）是 app 的**硬依赖**。
#
# iOS 上这些 crate 不单独出包，而是一起编进伞形静态库（std 只有一份），经 Flutter/{Debug,Release}.xcconfig
# 可选 include 的生成 xcconfig 以 -force_load 链进 Runner。那条 include 是 `#include?`：伞形库没编过时
# FUSHI_IOS_NATIVE_LDFLAGS 为空、照样链接成功——对 optional 的成员（缺了判能力不可用）没问题，对硬依赖
# 不行。所以这里在编译前挡住三种情形：
#   1. 当前 SDK（iphoneos / iphonesimulator）的伞形库 .a 不存在；
#   2. FUSHI_IOS_NATIVE_LDFLAGS 为空（生成的 xcconfig 缺席或不含当前 SDK 的切片）；
#   3. .a 是某个 crate 加入伞形库之前编的旧件（不导出它的 abi_symbol）。
# 修法一律是重跑 native/fushi_ios_umbrella/build_ios_staticlib.sh（device / simulator / all）。
set -euo pipefail

repo="${PROJECT_DIR}/../.."
sdk="${PLATFORM_NAME:-iphoneos}"
archive="$repo/native/fushi_ios_umbrella/prebuilt/ios/${sdk}/libfushi_ios_umbrella.a"
case "$sdk" in
  iphonesimulator) which=simulator ;;
  *) which=device ;;
esac
fix="run native/fushi_ios_umbrella/build_ios_staticlib.sh ${which} (needs Rust: rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios)"
py=python3
command -v python3 >/dev/null 2>&1 || py=/usr/bin/python3
checks="$("$py" "$repo/tool/native_crates.py" ios-checks)"
[[ -n "$checks" ]] || { echo "error: tool/native_crates.py ios-checks listed nothing (native/crates.json)" >&2; exit 1; }
required="$(printf '%s\n' "$checks" | cut -f1 | tr '\n' ' ')"

if [[ ! -f "$archive" ]]; then
  echo "error: ${required% } are required native dependencies, but the iOS umbrella staticlib is missing: ${archive}; ${fix}" >&2
  exit 1
fi
if [[ -z "${FUSHI_IOS_NATIVE_LDFLAGS:-}" ]]; then
  echo "error: FUSHI_IOS_NATIVE_LDFLAGS is empty for ${sdk} (generated native/fushi_ios_umbrella/prebuilt/ios/fushi_ios_umbrella.xcconfig missing or stale); ${fix}" >&2
  exit 1
fi
# nm 的退出码不作数（rustc 的 bitcode 成员可能读不了，见 build_ios_staticlib.sh），只看有没有这个符号。
exported="$({ nm -gU "$archive" 2>/dev/null || true; } | awk 'NF >= 2 { print $NF }')"
failed=0
while IFS=$'\t' read -r crate symbol; do
  if ! printf '%s\n' "$exported" | grep -qx "_${symbol}"; then
    echo "error: ${archive} does not export ${symbol} (built before ${crate} joined the umbrella); ${fix}" >&2
    failed=1
    continue
  fi
  echo "${crate}: ${archive} ok"
done <<< "$checks"
exit "$failed"
