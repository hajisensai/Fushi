#!/usr/bin/env bash
# FFmpegKitNext options for the unified FFmpeg on Android and iOS. Sourced by
# build_android.sh / build_ios.sh; the guard test pins these lists.
#
# Libraries cover card mining (x264 / VP9 / SVT-AV1 / WebP / Opus encoders,
# dav1d), the libmpv player that links the same libraries (libxml2 for DASH,
# OpenSSL for HTTPS + the tls_pin_sha256 patch), and zlib (PNG encoder).
# Hardware DECODING (MediaCodec / VideoToolbox) is on for playback; encoding
# stays software (mining quality, deterministic output across devices).

# shellcheck disable=SC2034
KIT_COMMON_OPTIONS=(
  --enable-gpl
  --enable-lib-x264
  --enable-lib-libvpx
  --enable-lib-opus
  --enable-lib-dav1d
  --enable-lib-libsvtav1
  --enable-lib-libwebp
  --enable-lib-openssl
  --enable-lib-libxml2
)

# shellcheck disable=SC2034
KIT_ANDROID_OPTIONS=(
  --enable-lib-android-media-codec
  --enable-lib-android-zlib
  --api-level=24
  # One plain armeabi-v7a build: libmpv links libavcodec.so by its plain name,
  # so the *_neon.so variant set (picked at runtime by abidetect) must not exist.
  --disable-arch-arm-v7a-neon
  # Flutter has no 32-bit x86 target.
  --disable-arch-x86
)

# macOS (desktop): no in-process runner is used (CliFfmpegBackend runs the
# ffmpeg/ffprobe programs), but the libraries are the player's and the
# programs' FFmpeg. Fushi ships Apple Silicon only.
# shellcheck disable=SC2034
KIT_MACOS_OPTIONS=(
  --xcframework
  --enable-lib-macos-videotoolbox
  --enable-lib-macos-audiotoolbox
  --enable-lib-macos-zlib
  --enable-lib-macos-bzip2
  --disable-arch-x86-64
)

# shellcheck disable=SC2034
KIT_IOS_OPTIONS=(
  --xcframework
  --enable-lib-ios-videotoolbox
  --enable-lib-ios-audiotoolbox
  --enable-lib-ios-zlib
  --enable-lib-ios-bzip2
  --disable-arch-arm64-mac-catalyst
  --disable-arch-x86-64-mac-catalyst
  --disable-arch-arm64e
)
