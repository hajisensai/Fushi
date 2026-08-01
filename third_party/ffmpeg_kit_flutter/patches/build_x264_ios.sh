#!/bin/bash
# TODO-2357: rebuild iOS ffmpeg-kit with libx264 (GPL) + keep openssl/cert-pin.
set -o pipefail
TOOLS="$HOME/ffmpegkit-build/tools"
export https_proxy=http://127.0.0.1:7897 http_proxy=http://127.0.0.1:7897 all_proxy=socks5://127.0.0.1:7897
export JAVA_HOME=$HOME/ffmpegkit-build/jdk/jdk-17.0.19+10/Contents/Home
export PATH=$TOOLS/bin:$JAVA_HOME/bin:/opt/homebrew/bin:$PATH
export LANG=en_US.UTF-8
cd "$HOME/ffmpegkit-build/ffmpeg-kit" || exit 9
echo "=== confirm cert-pin patch present before build ==="
grep -c ff_tls_check_cert_pin src/ffmpeg/libavformat/tls.c || { echo "PATCH MISSING"; exit 8; }
echo "=== ios.sh --enable-gpl --enable-x264 --enable-openssl --xcframework START $(date) ==="
./ios.sh --enable-gpl --enable-x264 --enable-openssl --xcframework
echo "IOS_X264_EXIT=$?"
echo "=== DONE $(date) ==="
