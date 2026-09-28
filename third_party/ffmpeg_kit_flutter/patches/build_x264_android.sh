#!/bin/bash
# Android ffmpeg-kit 配方（唯一真相源，构建机与 CI 共用）：
# - TODO-2357：libx264（GPL，片段导出全平台 H.264）+ openssl（BUG-891 远端 https 输入）
#   + cert-pin 补丁（ffmpeg-tls-pin-sha256.patch，须在构建前已打到 src/ffmpeg 上）。
# - 制卡「音画同步片段」默认 WebM：libvpx（VP9 编码器 libvpx-vp9）+ opus（libopus 编码器）。
#   WebM muxer 是 FFmpeg 内置、ffmpeg-kit 默认就编进来，不需要额外开关。
#
# 两种运行方式：
# - 构建机（Mac，`~/ffmpegkit-build/` 存在）：沿用构建机自带的 JDK / SDK / NDK / 代理。
# - CI（.github/workflows/ffmpeg-kit-android.yml）：由 workflow 预先设好 FFMPEG_KIT_DIR、
#   ANDROID_SDK_ROOT、ANDROID_NDK_ROOT、JAVA_HOME，本脚本只负责开关与校验。
set -o pipefail
if [ -d "$HOME/ffmpegkit-build" ] && [ -z "${FFMPEG_KIT_DIR:-}" ]; then
  TOOLS="$HOME/ffmpegkit-build/tools"
  export https_proxy=http://127.0.0.1:7897 http_proxy=http://127.0.0.1:7897 all_proxy=socks5://127.0.0.1:7897
  export JAVA_HOME=$HOME/ffmpegkit-build/jdk/jdk-17.0.19+10/Contents/Home
  export PATH=$TOOLS/bin:$JAVA_HOME/bin:$HOME/ffmpegkit-build/sdk/cmake/3.22.1/bin:$PATH
  export ANDROID_SDK_ROOT=$HOME/ffmpegkit-build/sdk
  export ANDROID_NDK_ROOT=$HOME/ffmpegkit-build/sdk/ndk/25.2.9519653
  export GRADLE_OPTS="-Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=7897 -Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=7897"
fi
FFMPEG_KIT_DIR="${FFMPEG_KIT_DIR:-$HOME/ffmpegkit-build/ffmpeg-kit}"
cd "$FFMPEG_KIT_DIR" || exit 9
echo "=== confirm cert-pin patch present before build ==="
grep -c ff_tls_check_cert_pin src/ffmpeg/libavformat/tls.c || { echo "PATCH MISSING"; exit 8; }
echo "=== android.sh --enable-gpl --enable-x264 --enable-openssl --enable-libvpx --enable-opus START $(date) ==="
./android.sh --enable-gpl --enable-x264 --enable-openssl --enable-libvpx --enable-opus \
  --disable-x86 --disable-x86-64 --api-level=24
ANDROID_EXIT=$?
echo "ANDROID_BUILD_EXIT=$ANDROID_EXIT"
echo "=== AAR list ==="
find . -name "ffmpeg-kit.aar" 2>/dev/null
echo "=== DONE $(date) ==="
exit $ANDROID_EXIT
