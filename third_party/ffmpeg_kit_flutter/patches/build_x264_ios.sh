#!/bin/bash
# Rebuild iOS ffmpeg-kit (arthenica v6.0) xcframeworks: libx264 (GPL, TODO-2357) +
# openssl/cert-pin (BUG-891) + libvpx/libopus (inline WebM clip export) + dav1d (BUG-2947:
# software AV1 decoder; the native `av1` decoder is hwaccel-only and --disable-videotoolbox
# leaves no hwaccel, so AV1 sources failed every frame/GIF extraction).
#
# Two callers, one recipe:
#   - Mac build box: run with no env -> ~/ffmpegkit-build layout + local proxy (as before).
#   - CI (.github/workflows/ffmpeg-kit-mobile.yml): sets FFMPEG_KIT_DIR and PATH itself.
#
# Needs nasm (x264 x86_64 simulator slice) and yasm (libvpx x86_64 simulator slice,
# scripts/apple/libvpx.sh passes --as=yasm), GNU libtoolize for opus autoreconf, and
# meson + ninja for dav1d (scripts/apple/dav1d.sh).
#
# Mac Catalyst is explicitly disabled: ios.sh enables arm64/x86-64-mac-catalyst by default
# (scripts/function-ios.sh:7-17) and nothing in the SDK check turns them off on SDK >= 14,
# but the vendored xcframeworks only carry ios-arm64_arm64e + ios-arm64_x86_64-simulator
# and the podspec is iOS-only. Disabling keeps the output slice set identical to the repo.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "${CI:-}" != "true" ]; then
  TOOLS="$HOME/ffmpegkit-build/tools"
  export https_proxy=http://127.0.0.1:7897 http_proxy=http://127.0.0.1:7897 all_proxy=socks5://127.0.0.1:7897
  export JAVA_HOME=$HOME/ffmpegkit-build/jdk/jdk-17.0.19+10/Contents/Home
  export PATH=$TOOLS/bin:$JAVA_HOME/bin:/opt/homebrew/bin:$PATH
fi
export LANG=en_US.UTF-8

FFMPEG_KIT_DIR="${FFMPEG_KIT_DIR:-$HOME/ffmpegkit-build/ffmpeg-kit}"

for tool in nasm yasm autoreconf libtoolize pkg-config meson ninja; do
  command -v "${tool}" >/dev/null || { echo "(*) ${tool} not found in PATH"; exit 6; }
done

echo "=== prepare src/ffmpeg (clone n6.0 if absent + cert-pin patch) ==="
bash "${HERE}/prepare_ffmpeg_src.sh" "${FFMPEG_KIT_DIR}"

cd "${FFMPEG_KIT_DIR}"
echo "=== ios.sh --enable-gpl --enable-x264 --enable-openssl --enable-libvpx --enable-opus --enable-dav1d --xcframework START $(date) ==="
rc=0
./ios.sh --enable-gpl --enable-x264 --enable-openssl --enable-libvpx --enable-opus --enable-dav1d --xcframework \
  --disable-arm64-mac-catalyst --disable-x86-64-mac-catalyst || rc=$?
echo "IOS_BUILD_EXIT=${rc}"
if [ "${rc}" -ne 0 ]; then
  echo "=== build.log (last 200 lines) ==="
  tail -n 200 build.log || true
  exit "${rc}"
fi

XCF_DIR="${FFMPEG_KIT_DIR}/prebuilt/bundle-apple-xcframework-ios"
[ -d "${XCF_DIR}" ] || { echo "xcframework dir not found at ${XCF_DIR}"; exit 7; }
ls -1 "${XCF_DIR}"
python3 "${HERE}/verify_mobile_outputs.py" ios "${XCF_DIR}"
echo "=== DONE $(date) ==="
