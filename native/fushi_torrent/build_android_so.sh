#!/usr/bin/env bash
# CI（Linux）版 Android .so 构建：与 build_android_so.ps1 完全同一套流程/产物布局，
# 供 release.yml 在 flutter build apk 前调用。详细决策注释见 .ps1 版与 README。
#
# 用法: build_android_so.sh <vcpkg-root> <ndk-root> [abi ...]
#   abi 缺省 arm64-v8a。产物: prebuilt/android/<abi>/libfushi_torrent_ffi.so
set -euo pipefail

VCPKG_ROOT="${1:?usage: build_android_so.sh <vcpkg-root> <ndk-root> [abi ...]}"
NDK_ROOT="${2:?usage: build_android_so.sh <vcpkg-root> <ndk-root> [abi ...]}"
shift 2
ABIS=("${@:-arm64-v8a}")

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

triplet_for_abi() {
  case "$1" in
    arm64-v8a)   echo arm64-android ;;
    armeabi-v7a) echo arm-neon-android ;;
    x86_64)      echo x64-android ;;
    x86)         echo x86-android ;;
    *) echo "unknown ABI: $1" >&2; return 1 ;;
  esac
}

export ANDROID_NDK_HOME="$NDK_ROOT"
ANDROID_TOOLCHAIN="$NDK_ROOT/build/cmake/android.toolchain.cmake"
VCPKG_TOOLCHAIN="$VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake"
[[ -f "$ANDROID_TOOLCHAIN" ]] || { echo "NDK toolchain missing: $ANDROID_TOOLCHAIN" >&2; exit 1; }

# vcpkg.json 的 builtin-baseline 只从 vcpkg 仓库本地 .git 读，取不到就硬失败，vcpkg
# 自己不 fetch；而版本条目来自工作区 versions/（跟着 HEAD 走）。充分条件是「baseline
# 是本地 HEAD 的祖先」——versions/ 只增不删。同款检查见 vcpkg_baseline.ps1。
baseline="$(sed -n 's/.*"builtin-baseline"[[:space:]]*:[[:space:]]*"\([0-9a-f]*\)".*/\1/p' "$SCRIPT_DIR/vcpkg.json")"
[[ -n "$baseline" ]] || { echo "vcpkg.json 缺少 builtin-baseline" >&2; exit 1; }
if [[ "$(git -C "$VCPKG_ROOT" cat-file -t "$baseline" 2>/dev/null)" != commit ]]; then
  echo "==> fetch vcpkg baseline $baseline"
  git -C "$VCPKG_ROOT" fetch --no-tags --quiet origin "$baseline" \
    || { echo "取不到 vcpkg baseline $baseline（$VCPKG_ROOT 无法 fetch）" >&2; exit 1; }
fi
if ! git -C "$VCPKG_ROOT" merge-base --is-ancestor "$baseline" HEAD; then
  echo "vcpkg 太旧：$VCPKG_ROOT 的 HEAD 不是 baseline $baseline 的后代。" >&2
  echo "修复：git -C \"$VCPKG_ROOT\" pull" >&2
  exit 1
fi

for abi in "${ABIS[@]}"; do
  triplet="$(triplet_for_abi "$abi")"
  # 依赖不再用 classic `vcpkg install` 单独装：vcpkg.json（manifest + overrides）
  # 把 libtorrent 钉在 2.0.11，cmake configure 时 vcpkg 工具链自动按它装。
  # BUG-1772：classic 模式的版本由 vcpkg 修订当下的 ports 决定，2026-08 漂到
  # 2.1 后 Windows DLL 与 Android .so 一起编不出来。

  build_dir="$SCRIPT_DIR/build-android-$abi"
  echo "==> cmake configure ($abi / $triplet)"
  # VCPKG_OVERLAY_TRIPLETS 必须给 cmake：manifest 模式下是工具链在装依赖，只传给
  # `vcpkg install` 的话 overlay 不参与，会静默退回 vcpkg 自带 arm64-android（API 28），
  # 即 vcpkg-triplets/ 注释里那个 aligned_alloc undefined symbol。
  cmake -G Ninja -B "$build_dir" -S "$SCRIPT_DIR" \
    "-DCMAKE_TOOLCHAIN_FILE=$VCPKG_TOOLCHAIN" \
    "-DVCPKG_TARGET_TRIPLET=$triplet" \
    "-DVCPKG_OVERLAY_TRIPLETS=$SCRIPT_DIR/vcpkg-triplets" \
    "-DVCPKG_CHAINLOAD_TOOLCHAIN_FILE=$ANDROID_TOOLCHAIN" \
    "-DANDROID_ABI=$abi" \
    "-DANDROID_PLATFORM=android-24" \
    "-DANDROID_STL=c++_shared" \
    "-DCMAKE_BUILD_TYPE=Release"
  cmake --build "$build_dir"

  so="$build_dir/libfushi_torrent_ffi.so"
  [[ -f "$so" ]] || { echo "missing artifact: $so" >&2; exit 1; }

  out_dir="$SCRIPT_DIR/prebuilt/android/$abi"
  mkdir -p "$out_dir"
  cp -f "$so" "$out_dir/libfushi_torrent_ffi.so"

  strip_bin="$NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"
  if [[ -x "$strip_bin" ]]; then
    "$strip_bin" --strip-unneeded "$out_dir/libfushi_torrent_ffi.so"
  else
    echo "WARN: llvm-strip not found ($strip_bin) — artifact not stripped" >&2
  fi
  ls -lh "$out_dir/libfushi_torrent_ffi.so"
done
