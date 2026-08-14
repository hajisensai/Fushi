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

for abi in "${ABIS[@]}"; do
  triplet="$(triplet_for_abi "$abi")"
  echo "==> vcpkg install libtorrent:$triplet"
  "$VCPKG_ROOT/vcpkg" install "libtorrent:$triplet"

  build_dir="$SCRIPT_DIR/build-android-$abi"
  echo "==> cmake configure ($abi / $triplet)"
  cmake -G Ninja -B "$build_dir" -S "$SCRIPT_DIR" \
    "-DCMAKE_TOOLCHAIN_FILE=$VCPKG_TOOLCHAIN" \
    "-DVCPKG_TARGET_TRIPLET=$triplet" \
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
