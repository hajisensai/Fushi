#!/usr/bin/env bash
# Cross-build the tool/dvd libraries for one mobile / Apple target and stage a
# development tarball next to the unified FFmpeg's ffmpeg-dev-* tarballs:
#
#   <out>/dvd-dev-<target>.tar.gz   include/ + lib/*.{so,dylib} + lib/pkgconfig
#
# Both consumers link the SAME shared libraries from it (only one copy per
# app): the unified FFmpeg (--enable-libdvdnav --enable-libdvdread, dvdvideo
# demuxer) and libmpv (-Ddvdnav=enabled, dvd:// menus).
#
# STATUS (2026-10-24): written and syntax-checked only; no target below has
# been built yet. Android needs a Linux/macOS host with NDK r27d; Apple
# targets need Xcode. See tool/dvd/README.md for what still has to happen in
# the FFmpegKitNext and libmpv fork builds before an artifact can be vendored.
#
# Usage: build_cross.sh <target> <work-dir> <out-dir>
#   target: android-arm64-v8a | android-armeabi-v7a | android-x86_64 |
#           ios-arm64 | ios-simulator-arm64 | macos-arm64
# Android needs ANDROID_NDK_ROOT; Apple targets need xcrun.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:?usage: build_cross.sh <target> <work-dir> <out-dir>}"
WORK="${2:?usage: build_cross.sh <target> <work-dir> <out-dir>}"
OUT="${3:?usage: build_cross.sh <target> <work-dir> <out-dir>}"
mkdir -p "${WORK}" "${OUT}"
WORK="$(cd "${WORK}" && pwd)"
OUT="$(cd "${OUT}" && pwd)"
PREFIX="${WORK}/prefix-${TARGET}"
CROSS="${WORK}/cross-${TARGET}.ini"

android_cross() {
  local triple="$1" cpu_family="$2" cpu="$3"
  : "${ANDROID_NDK_ROOT:?ANDROID_NDK_ROOT must be set}"
  # Linux / macOS hosts only: meson on a Windows host rejects a C:/ prefix for
  # an Android (POSIX) host machine ("prefix value ... must be an absolute path").
  case "$(uname -s)" in Linux|Darwin) ;; *)
    echo "build_cross: build Android targets on Linux or macOS" >&2; exit 2 ;;
  esac
  local bin
  bin="$(echo "${ANDROID_NDK_ROOT}"/toolchains/llvm/prebuilt/*/bin)"
  # API 24 = the app's minSdk; 16 KB pages for Android 15+ (Google Play).
  cat > "${CROSS}" <<EOF
[binaries]
c = '${bin}/clang'
ar = '${bin}/llvm-ar'
strip = '${bin}/llvm-strip'
pkg-config = 'pkg-config'

[built-in options]
c_args = ['--target=${triple}24']
c_link_args = ['--target=${triple}24', '-Wl,-z,max-page-size=16384']

[host_machine]
system = 'android'
cpu_family = '${cpu_family}'
cpu = '${cpu}'
endian = 'little'
EOF
}

apple_cross() {
  local sdk="$1" target="$2" system="$3"
  local sysroot cc defines=""
  # iOS has no optical drive / IOKit DVD client: libdvdcss reads images only
  # (tool/dvd/patches/libdvdcss/0001-no-drive-ioctls.patch).
  [ "${system}" = ios ] && defines=", '-DFUSHI_DVDCSS_NO_DRIVE'"
  sysroot="$(xcrun --sdk "${sdk}" --show-sdk-path)"
  cc="$(xcrun --sdk "${sdk}" --find clang)"
  # @rpath install names: the app's Frameworks directory, like the FFmpeg
  # frameworks libmpv already links.
  cat > "${CROSS}" <<EOF
[binaries]
c = '${cc}'
objc = '${cc}'
ar = '$(xcrun --sdk "${sdk}" --find ar)'
strip = '$(xcrun --sdk "${sdk}" --find strip)'
pkg-config = 'pkg-config'

[built-in options]
c_args = ['-target', '${target}', '-isysroot', '${sysroot}'${defines}]
c_link_args = ['-target', '${target}', '-isysroot', '${sysroot}', '-Wl,-headerpad_max_install_names']

[host_machine]
system = '${system}'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
EOF
}

case "${TARGET}" in
  android-arm64-v8a) android_cross aarch64-linux-android aarch64 armv8 ;;
  android-armeabi-v7a) android_cross armv7a-linux-androideabi arm armv7 ;;
  android-x86_64) android_cross x86_64-linux-android x86_64 x86_64 ;;
  ios-arm64) apple_cross iphoneos arm64-apple-ios13.0 ios ;;
  ios-simulator-arm64) apple_cross iphonesimulator arm64-apple-ios13.0-simulator ios ;;
  macos-arm64) apple_cross macosx arm64-apple-macos11.0 darwin ;;
  *) echo "build_cross: unknown target ${TARGET}" >&2; exit 2 ;;
esac

bash "${HERE}/../build_dvd_libs.sh" "${WORK}/build-${TARGET}" "${PREFIX}" "${CROSS}"

case "${TARGET}" in
  macos-*|ios-*)
    # Install names and the libdvdnav -> libdvdread -> libdvdcss references
    # are absolute build-prefix paths; make all of them @rpath, then prove it.
    for lib in "${PREFIX}"/lib/libdvd*.dylib; do
      [ -L "${lib}" ] && continue
      install_name_tool -id "@rpath/$(basename "${lib}")" "${lib}"
      for dep in $(otool -L "${lib}" | awk 'NR > 1 {print $1}' | grep "^${PREFIX}/" || true); do
        install_name_tool -change "${dep}" "@rpath/$(basename "${dep}")" "${lib}"
      done
    done
    for lib in "${PREFIX}"/lib/libdvd*.dylib; do
      # Line 1 of otool -L is the file name itself; the rest are load commands.
      if otool -L "${lib}" | awk 'NR > 1 {print $1}' | grep -q "^${PREFIX}/"; then
        echo "build_cross: ${lib} still references the build prefix" >&2
        exit 6
      fi
    done
    ;;
esac

tar -C "${PREFIX}" -czf "${OUT}/dvd-dev-${TARGET}.tar.gz" include lib share/licenses/fushi-dvd
echo "build_cross: ${OUT}/dvd-dev-${TARGET}.tar.gz"
