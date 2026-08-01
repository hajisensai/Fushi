#!/bin/bash
# TODO-2357: rebuild Android ffmpeg-kit with libx264 (GPL) + keep openssl/cert-pin.
set -o pipefail
TOOLS="$HOME/ffmpegkit-build/tools"
export https_proxy=http://127.0.0.1:7897 http_proxy=http://127.0.0.1:7897 all_proxy=socks5://127.0.0.1:7897
export JAVA_HOME=$HOME/ffmpegkit-build/jdk/jdk-17.0.19+10/Contents/Home
export PATH=$TOOLS/bin:$JAVA_HOME/bin:$HOME/ffmpegkit-build/sdk/cmake/3.22.1/bin:$PATH
export ANDROID_SDK_ROOT=$HOME/ffmpegkit-build/sdk
export ANDROID_NDK_ROOT=$HOME/ffmpegkit-build/sdk/ndk/25.2.9519653
export GRADLE_OPTS="-Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=7897 -Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=7897"
cd "$HOME/ffmpegkit-build/ffmpeg-kit" || exit 9
echo "=== confirm cert-pin patch present before build ==="
grep -c ff_tls_check_cert_pin src/ffmpeg/libavformat/tls.c || { echo "PATCH MISSING"; exit 8; }
echo "=== android.sh --enable-gpl --enable-x264 --enable-openssl START $(date) ==="
./android.sh --enable-gpl --enable-x264 --enable-openssl --disable-x86 --disable-x86-64 --api-level=24
echo "ANDROID_X264_EXIT=$?"
echo "=== AAR list ==="
find . -name "ffmpeg-kit.aar" 2>/dev/null
echo "=== DONE $(date) ==="
