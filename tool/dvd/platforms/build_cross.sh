#!/usr/bin/env bash
# Cross-build the tool/dvd libraries for one mobile / Apple target:
#
#   <work>/<target>/                  install prefix (include/, lib/, lib/pkgconfig/)
#                                     = FUSHI_DVD_ROOT/<target> for the FFmpegKitNext
#                                     patch (patches/ffmpeg-kit-next/0003-*)
#   <work>/<target>/frameworks/       Apple only: libdvd{css,read,nav}.framework
#   <out>/dvd-dev-<target>.tar.gz     the prefix, for the libmpv fork builds
#
# Both consumers link the SAME shared libraries (one copy per app): the unified
# FFmpeg (--enable-libdvdnav --enable-libdvdread, dvdvideo demuxer) and libmpv
# (-Ddvdnav=enabled, dvd:// menus).
#
# Android: plain lib<name>.so (meson does not version shared libraries for an
# Android host, so DT_SONAME / DT_NEEDED are the unversioned names the APK
# packs). Apple: each dylib's install name is @rpath/<lib>.framework/<lib>, so
# whatever links it (libavformat, Mpv) loads the framework the app embeds.
#
# Status and what was built where: tool/dvd/README.md.
#
# Usage: build_cross.sh <target> <work-dir> <out-dir>
#   target: android-arm64-v8a | android-armeabi-v7a | android-x86_64 |
#           ios-arm64 | ios-simulator-arm64 | ios-simulator-x86_64 | macos-arm64
# Android needs ANDROID_NDK_ROOT on a Linux / macOS host; Apple needs Xcode.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:?usage: build_cross.sh <target> <work-dir> <out-dir>}"
WORK="${2:?usage: build_cross.sh <target> <work-dir> <out-dir>}"
OUT="${3:?usage: build_cross.sh <target> <work-dir> <out-dir>}"
mkdir -p "${WORK}" "${OUT}"
WORK="$(cd "${WORK}" && pwd)"
OUT="$(cd "${OUT}" && pwd)"
PREFIX="${WORK}/${TARGET}"
CROSS="${WORK}/cross-${TARGET}.ini"
# Kept in sync with FFmpegKitNext's -mios-version-min / macOS minimum.
IOS_MIN=13.0
MACOS_MIN=11.0

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
  local sdk="$1" target="$2" system="$3" cpu_family="$4" cpu="$5"
  local sysroot cc defines=""
  # iOS has no optical drive / IOKit DVD client: libdvdcss reads images only
  # (tool/dvd/patches/libdvdcss/0001-no-drive-ioctls.patch).
  [ "${system}" = ios ] && defines=", '-DFUSHI_DVDCSS_NO_DRIVE'"
  sysroot="$(xcrun --sdk "${sdk}" --show-sdk-path)"
  cc="$(xcrun --sdk "${sdk}" --find clang)"
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
cpu_family = '${cpu_family}'
cpu = '${cpu}'
endian = 'little'
EOF
}

case "${TARGET}" in
  android-arm64-v8a) android_cross aarch64-linux-android aarch64 armv8 ;;
  android-armeabi-v7a) android_cross armv7a-linux-androideabi arm armv7 ;;
  android-x86_64) android_cross x86_64-linux-android x86_64 x86_64 ;;
  ios-arm64) apple_cross iphoneos "arm64-apple-ios${IOS_MIN}" ios aarch64 arm64 ;;
  ios-simulator-arm64)
    apple_cross iphonesimulator "arm64-apple-ios${IOS_MIN}-simulator" ios aarch64 arm64 ;;
  ios-simulator-x86_64)
    apple_cross iphonesimulator "x86_64-apple-ios${IOS_MIN}-simulator" ios x86_64 x86_64 ;;
  macos-arm64) apple_cross macosx "arm64-apple-macos${MACOS_MIN}" darwin aarch64 arm64 ;;
  *) echo "build_cross: unknown target ${TARGET}" >&2; exit 2 ;;
esac

rm -rf "${PREFIX}"
bash "${HERE}/../build_dvd_libs.sh" "${WORK}/build-${TARGET}" "${PREFIX}" "${CROSS}"

framework_plist() {
  local name="$1" platform="$2" min="$3" version
  version="$(pkg-config --modversion "$(case "${name}" in
    libdvdcss) echo libdvdcss ;; libdvdread) echo dvdread ;; *) echo dvdnav ;; esac)")"
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>${name}</string>
  <key>CFBundleIdentifier</key><string>moe.fushi.dvd.${name}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>${name}</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
  <key>CFBundleVersion</key><string>${version}</string>
  <key>CFBundleSupportedPlatforms</key><array><string>${platform}</string></array>
  <key>MinimumOSVersion</key><string>${min}</string>
</dict>
</plist>
EOF
}

case "${TARGET}" in
  macos-*|ios-*)
    # Install names and the libdvdnav -> libdvdread -> libdvdcss references are
    # absolute build-prefix paths; make them @rpath/<lib>.framework/<lib>.
    export PKG_CONFIG_LIBDIR="${PREFIX}/lib/pkgconfig"
    for lib in "${PREFIX}"/lib/libdvd*.dylib; do
      [ -L "${lib}" ] && continue
      name="$(basename "${lib}" | cut -d. -f1)"
      install_name_tool -id "@rpath/${name}.framework/${name}" "${lib}"
      for dep in $(otool -L "${lib}" | awk 'NR > 1 {print $1}' | grep "^${PREFIX}/" || true); do
        dep_name="$(basename "${dep}" | cut -d. -f1)"
        install_name_tool -change "${dep}" "@rpath/${dep_name}.framework/${dep_name}" "${lib}"
      done
    done
    for lib in "${PREFIX}"/lib/libdvd*.dylib; do
      [ -L "${lib}" ] && continue
      # Line 1 of otool -L is the file name itself; the rest are load commands.
      if otool -L "${lib}" | awk 'NR > 1 {print $1}' | grep -q "^${PREFIX}/"; then
        echo "build_cross: ${lib} still references the build prefix" >&2
        exit 6
      fi
    done
    # Frameworks: iOS uses the flat bundle layout, macOS the versioned one.
    rm -rf "${PREFIX}/frameworks"
    for lib in "${PREFIX}"/lib/libdvd*.dylib; do
      [ -L "${lib}" ] && continue
      name="$(basename "${lib}" | cut -d. -f1)"
      fw="${PREFIX}/frameworks/${name}.framework"
      case "${TARGET}" in
        macos-*)
          mkdir -p "${fw}/Versions/A/Resources"
          cp "${lib}" "${fw}/Versions/A/${name}"
          framework_plist "${name}" MacOSX "${MACOS_MIN}" > "${fw}/Versions/A/Resources/Info.plist"
          cp "${PREFIX}/share/licenses/fushi-dvd/${name}-COPYING" "${fw}/Versions/A/Resources/COPYING"
          ln -s A "${fw}/Versions/Current"
          ln -s "Versions/Current/${name}" "${fw}/${name}"
          ln -s Versions/Current/Resources "${fw}/Resources"
          ;;
        *)
          mkdir -p "${fw}"
          cp "${lib}" "${fw}/${name}"
          platform=iPhoneOS
          [ "${TARGET#ios-simulator}" != "${TARGET}" ] && platform=iPhoneSimulator
          framework_plist "${name}" "${platform}" "${IOS_MIN}" > "${fw}/Info.plist"
          cp "${PREFIX}/share/licenses/fushi-dvd/${name}-COPYING" "${fw}/COPYING"
          ;;
      esac
    done
    ;;
esac

contents=(include lib share/licenses/fushi-dvd)
[ -d "${PREFIX}/frameworks" ] && contents+=(frameworks)
tar -C "${PREFIX}" -czf "${OUT}/dvd-dev-${TARGET}.tar.gz" "${contents[@]}"
echo "build_cross: ${OUT}/dvd-dev-${TARGET}.tar.gz"
