#!/usr/bin/env bash
# BUG-3482 真 WebKit 真触摸对照实验（Mac，iOS 模拟器）。
#
#   bash run_probe.sh <udid>
#
# 先在 Fushi 的 iOS 集成测试里导出实验页（reader_cross_axis_lock_itest.dart 带
# --dart-define=FUSHI_XAXIS_DUMP=1 跑一遍，写到宿主 /tmp/fushi-xaxis/variants/），
# 再跑这里：xcodegen 生成工程 → build-for-testing → 逐页真触摸拖动 → 打印每页
# UIScrollView 的 contentSize 与各次拖动的 contentOffset 范围。
set -u
export PATH=/opt/homebrew/bin:$PATH
UDID=${1:?udid}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ls /tmp/fushi-xaxis/variants/*.html >/dev/null 2>&1 || { echo "no variants in /tmp/fushi-xaxis/variants"; exit 2; }
rm -f /tmp/fushi-xaxis/offsets.log
cd "$HERE" && xcodegen generate >/dev/null && xcodebuild build-for-testing \
  -project WebKitPanProbe.xcodeproj -scheme WebKitPanProbe -destination "id=$UDID" \
  -derivedDataPath "$HERE/dd" 2>&1 | grep -E "error|BUILD"
RUN="$(ls "$HERE"/dd/Build/Products/WebKitPanProbe_iphonesimulator*.xctestrun | head -1)"
caffeinate -u -t 2
xcodebuild test-without-building -xctestrun "$RUN" -destination "id=$UDID" > "$HERE/dd/probe.log" 2>&1
echo "xcodebuild exit=$?"
python3 "$HERE/summarize.py" /tmp/fushi-xaxis/offsets.log
