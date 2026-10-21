#!/usr/bin/env bash
# Build the unified FFmpeg for Windows x64 (MSYS2 MINGW64), shared libraries
# plus the ffmpeg/ffprobe programs, into a PRIVATE prefix. libmpv is then built
# against this prefix (tool/bluray/build_libmpv.ps1), and the packaged runtime
# ships libmpv-2.dll, ffmpeg.exe and ffprobe.exe on one set of fbd*.dll.
#
# The configure set mirrors MSYS2's mingw-w64-ffmpeg 9.0.1-3 PKGBUILD (the
# FFmpeg the player shipped before unification, so playback capability is
# unchanged) minus components unrelated to playback and mining that only add
# DLL weight: whisper (ggml), librsvg (glib/cairo/pango), frei0r (needs an
# MSYS2-only relocation patch), libcaca and openal (avdevice outputs).
#
# Usage (MINGW64 shell): build_ffmpeg_msys2.sh <work-dir> [jobs]
#   <work-dir>/src     patched FFmpeg source (prepare_ffmpeg_src.sh)
#   <work-dir>/deps    header-only deps (nv-codec-headers, AMF)
#   <work-dir>/prefix  installed FFmpeg (bin/*.dll, ffmpeg.exe, include, lib/pkgconfig)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck source=../recipe.env
source "${ROOT}/recipe.env"

WORK="${1:?usage: build_ffmpeg_msys2.sh <work-dir> [jobs]}"
JOBS="${2:-8}"

# Header-only build inputs, pinned. MSYS2 ships them as packages, but they are
# fetched from upstream so the build never mutates the host MSYS2 install.
NV_CODEC_HEADERS_TAG=n13.0.19.1
AMF_TAG=v1.5.3

if [ "${MSYSTEM:-}" != "MINGW64" ]; then
  echo "build_ffmpeg_msys2: run in an MSYS2 MINGW64 shell (MSYSTEM=${MSYSTEM:-unset})" >&2
  exit 2
fi
if [ -e "${WORK}" ]; then
  echo "build_ffmpeg_msys2: use a new work dir (${WORK} exists)" >&2
  exit 2
fi
mkdir -p "${WORK}"
WORK="$(cd "${WORK}" && pwd)"
SRC="${WORK}/src"
DEPS="${WORK}/deps"
PREFIX="${WORK}/prefix"
BUILD="${WORK}/build"
# The install prefix is baked into the .pc files, which meson and the native
# gcc read without MSYS2's POSIX path translation, so it is passed mixed-style
# (C:/...). Everything else stays POSIX: PKG_CONFIG_PATH is ':'-separated and
# MSYS2 only converts POSIX path lists.
PREFIX_NATIVE="$(cygpath -m "${PREFIX}")"

bash "${ROOT}/prepare_ffmpeg_src.sh" "${SRC}"

git clone --quiet --depth 1 --branch "${NV_CODEC_HEADERS_TAG}" \
  https://github.com/FFmpeg/nv-codec-headers.git "${WORK}/nv-codec-headers"
make -C "${WORK}/nv-codec-headers" PREFIX="${DEPS}" install > /dev/null

git clone --quiet --depth 1 --branch "${AMF_TAG}" --filter=blob:none --sparse \
  https://github.com/GPUOpen-LibrariesAndSDKs/AMF.git "${WORK}/amf"
git -C "${WORK}/amf" sparse-checkout set amf/public/include
mkdir -p "${DEPS}/include/AMF"
cp -r "${WORK}/amf/amf/public/include/." "${DEPS}/include/AMF/"

config=(
  --prefix="${PREFIX_NATIVE}"
  --target-os=mingw32
  --arch=x86_64
  --cc=gcc
  --cxx=g++
  --disable-debug
  --disable-stripping
  --disable-doc
  --disable-static
  --enable-shared
  --enable-dxva2
  --enable-d3d11va
  --enable-d3d12va
  --enable-gmp
  --enable-gnutls
  --enable-gpl
  --enable-iconv
  --enable-libaom
  --enable-libass
  --enable-libbluray
  --enable-libdav1d
  --enable-libfontconfig
  --enable-libfreetype
  --enable-libfribidi
  --enable-libgme
  --enable-libgsm
  --enable-libharfbuzz
  --enable-libjxl
  --enable-libmodplug
  --enable-libmp3lame
  --enable-libopencore_amrnb
  --enable-libopencore_amrwb
  --enable-libopenjpeg
  --enable-libopus
  --enable-librtmp
  --enable-libssh
  --enable-libsoxr
  --enable-libspeex
  --enable-libsrt
  --enable-libtheora
  --enable-libvidstab
  --enable-libvorbis
  --enable-libx264
  --enable-libx265
  --enable-libxvid
  --enable-libvpx
  --enable-libwebp
  --enable-libxml2
  --enable-libzimg
  --enable-libzvbi
  --enable-pic
  --enable-runtime-cpudetect
  --enable-swresample
  --enable-version3
  --enable-vulkan
  --enable-zlib
  --enable-libvpl
  --enable-liblc3
  --enable-libplacebo
  --enable-librav1e
  --enable-libsvtav1
  --enable-amf
  --enable-nvenc
  --enable-ffnvcodec
  --enable-nvdec
  --enable-cuvid
  --extra-cflags="-I$(cygpath -m "${DEPS}")/include"
  --logfile=config.log
)

mkdir -p "${BUILD}"
cd "${BUILD}"
export PKG_CONFIG_PATH="${DEPS}/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
"${SRC}/configure" "${config[@]}"
make -j"${JOBS}"
make install

echo "build_ffmpeg_msys2: FFmpeg ${FFMPEG_VERSION} (+patches) -> ${PREFIX}"
"${PREFIX}/bin/ffmpeg.exe" -hide_banner -version | head -1
