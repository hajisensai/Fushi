#!/bin/bash
# Rebuild Android ffmpeg-kit (arthenica v6.0): libx264 (GPL, TODO-2357) + openssl/cert-pin
# (BUG-891) + libvpx/libopus (inline WebM clip export) + dav1d (BUG-2947: FFmpeg's native
# `av1` decoder is a hwaccel-only shell, and --disable-mediacodec leaves no hwaccel, so every
# AV1 source failed frame/GIF extraction with "doesn't support hardware accelerated AV1").
#
# dav1d is built with meson + ninja (scripts/android/dav1d.sh), so both must be on PATH.
#
# Two callers, one recipe:
#   - Mac build box: run with no env -> uses ~/ffmpegkit-build layout + local proxy (as before).
#   - CI (.github/workflows/ffmpeg-kit-mobile.yml): sets FFMPEG_KIT_DIR, ANDROID_SDK_ROOT,
#     ANDROID_NDK_ROOT, JAVA_HOME itself; CI=true skips the build-box env block.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "${CI:-}" != "true" ]; then
  TOOLS="$HOME/ffmpegkit-build/tools"
  export https_proxy=http://127.0.0.1:7897 http_proxy=http://127.0.0.1:7897 all_proxy=socks5://127.0.0.1:7897
  export JAVA_HOME=$HOME/ffmpegkit-build/jdk/jdk-17.0.19+10/Contents/Home
  export PATH=$TOOLS/bin:$JAVA_HOME/bin:$HOME/ffmpegkit-build/sdk/cmake/3.22.1/bin:$PATH
  export ANDROID_SDK_ROOT=$HOME/ffmpegkit-build/sdk
  export ANDROID_NDK_ROOT=$HOME/ffmpegkit-build/sdk/ndk/25.2.9519653
  export GRADLE_OPTS="-Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=7897 -Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=7897"
fi

FFMPEG_KIT_DIR="${FFMPEG_KIT_DIR:-$HOME/ffmpegkit-build/ffmpeg-kit}"
: "${ANDROID_SDK_ROOT:?ANDROID_SDK_ROOT not set}"
: "${ANDROID_NDK_ROOT:?ANDROID_NDK_ROOT not set}"

echo "=== prepare src/ffmpeg (clone n6.0 if absent + cert-pin patch) ==="
bash "${HERE}/prepare_ffmpeg_src.sh" "${FFMPEG_KIT_DIR}"

for tool in meson ninja; do
  command -v "${tool}" >/dev/null || { echo "(*) ${tool} not found in PATH (needed by dav1d)"; exit 6; }
done

# BUG-3503: --enable-libxml2 pulls libiconv on Android. ffmpeg-kit clones libiconv v1.17
# from git and runs `gitsub.sh pull`, whose gnulib is a plain "subcheckout" -> it clones
# gnulib *HEAD* (the arthenica mirror tracks upstream). Four years of gnulib drift break
# libiconv 1.17's autogen ("gl_HOST_CPU_C_ABI_32BIT: command not found", libcharset
# configure fails). Pin gnulib to the last commit before the v1.17 tag (2022-05-15
# 13:01 UTC) and hand it over via GNULIB_SRCDIR, which both gitsub.sh and autogen.sh honour.
GNULIB_PIN_SHA="4bc2b6f67259e3fb54d21d3b93e7cab12161f7fd"
GNULIB_PIN_DIR="${FFMPEG_KIT_DIR}/.tmp/gnulib-libiconv-1.17"
if [ "$(git -C "${GNULIB_PIN_DIR}" rev-parse HEAD 2>/dev/null)" != "${GNULIB_PIN_SHA}" ]; then
  rm -rf "${GNULIB_PIN_DIR}"
  mkdir -p "${GNULIB_PIN_DIR}"
  git -C "${GNULIB_PIN_DIR}" init -q
  git -C "${GNULIB_PIN_DIR}" fetch -q --depth 1 https://github.com/arthenica/gnulib "${GNULIB_PIN_SHA}"
  git -C "${GNULIB_PIN_DIR}" checkout -q FETCH_HEAD
fi
export GNULIB_SRCDIR="${GNULIB_PIN_DIR}"
echo "gnulib pinned for libiconv: $(git -C "${GNULIB_SRCDIR}" rev-parse HEAD)"

cd "${FFMPEG_KIT_DIR}"
echo "=== android.sh --enable-gpl --enable-x264 --enable-openssl --enable-libvpx --enable-opus --enable-dav1d --enable-libxml2 START $(date) ==="
rc=0
./android.sh --enable-gpl --enable-x264 --enable-openssl --enable-libvpx --enable-opus --enable-dav1d --enable-libxml2 \
  --disable-x86 --disable-x86-64 --api-level=24 || rc=$?
echo "ANDROID_BUILD_EXIT=${rc}"
if [ "${rc}" -ne 0 ]; then
  echo "=== build.log (last 200 lines) ==="
  tail -n 200 build.log || true
  exit "${rc}"
fi

AAR="${FFMPEG_KIT_DIR}/prebuilt/bundle-android-aar/ffmpeg-kit/ffmpeg-kit.aar"
[ -f "${AAR}" ] || { echo "AAR not found at ${AAR}"; exit 7; }
echo "AAR: ${AAR}"
python3 "${HERE}/verify_mobile_outputs.py" android "${AAR}"
echo "=== DONE $(date) ==="
