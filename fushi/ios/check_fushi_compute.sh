#!/usr/bin/env bash
# Xcode 构建阶段「Check fushi_compute (iOS umbrella)」：计算内核 fushi_compute 是 app 的**硬依赖**。
#
# iOS 上 fushi_compute 不单独出包，而是与 fushi_p2p / fushi_fsrs 一起编进伞形静态库
# native/fushi_ios_umbrella（std 只有一份），经 Flutter/{Debug,Release}.xcconfig 可选 include
# 的生成 xcconfig 以 -force_load 链进 Runner。那条 include 是 `#include?`：伞形库没编过时
# FUSHI_IOS_NATIVE_LDFLAGS 为空、照样链接成功——对 fushi_p2p / fushi_fsrs（缺了判能力不可用）
# 没问题，对硬依赖的 fushi_compute 不行。所以这里在编译前挡住三种情形：
#   1. 当前 SDK（iphoneos / iphonesimulator）的伞形库 .a 不存在；
#   2. FUSHI_IOS_NATIVE_LDFLAGS 为空（生成的 xcconfig 缺席或不含当前 SDK 的切片）；
#   3. .a 是加入 fushi_compute 之前编的旧件（不导出 ffc_abi_version）。
# 修法一律是重跑 native/fushi_ios_umbrella/build_ios_staticlib.sh（device / simulator / all）。
set -euo pipefail

sdk="${PLATFORM_NAME:-iphoneos}"
archive="${PROJECT_DIR}/../../native/fushi_ios_umbrella/prebuilt/ios/${sdk}/libfushi_ios_umbrella.a"
case "$sdk" in
  iphonesimulator) which=simulator ;;
  *) which=device ;;
esac
fix="run native/fushi_ios_umbrella/build_ios_staticlib.sh ${which} (needs Rust: rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios)"

if [[ ! -f "$archive" ]]; then
  echo "error: fushi_compute is a required native dependency, but the iOS umbrella staticlib is missing: ${archive}; ${fix}" >&2
  exit 1
fi
if [[ -z "${FUSHI_IOS_NATIVE_LDFLAGS:-}" ]]; then
  echo "error: FUSHI_IOS_NATIVE_LDFLAGS is empty for ${sdk} (generated native/fushi_ios_umbrella/prebuilt/ios/fushi_ios_umbrella.xcconfig missing or stale); ${fix}" >&2
  exit 1
fi
# nm 的退出码不作数（rustc 的 bitcode 成员可能读不了，见 build_ios_staticlib.sh），只看有没有这个符号。
if ! { nm -gU "$archive" 2>/dev/null || true; } | grep -q '_ffc_abi_version$'; then
  echo "error: ${archive} does not export ffc_abi_version (built before fushi_compute joined the umbrella); ${fix}" >&2
  exit 1
fi
echo "fushi_compute: ${archive} ok"
