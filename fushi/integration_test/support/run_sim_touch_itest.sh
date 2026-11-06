#!/usr/bin/env bash
# iOS 模拟器「真实触摸」集成测试编排（在装了 Xcode 的 Mac 上、fushi/ 目录的检出里跑）。
#
#   TEST=integration_test/ios_popup_real_touch_itest.dart \
#     bash integration_test/support/run_sim_touch_itest.sh [udid]
#
# 1. 卸载 Fushi 拿干净容器，后台 `flutter test $TEST -d <udid>`；
# 2. 等它的 Xcode 构建结束后再起 ios_touch_tapper（XCUITest）——flutter 的 xcodebuild
#    会打断同一模拟器上正在跑的 XCUITest 会话；
# 3. 桥：把测试日志里最新一行 `[ios-touch] TAP <seq> <x> <y> ...` 写成 $TAP_DIR/req，
#    tapper 在该屏幕坐标投真实触摸（模拟器 HID 通道，走 UIKit hitTest 真链路）。
# 测试侧必须先 `IosRealTouchSession.start(binding)`（见 ios_real_touch.dart：集成测试
# 绑定默认让 iOS 平台视图收不到任何真实触摸）。每次触摸后抓一张真屏到 $SHOTS。
set -u
export LANG=en_US.UTF-8
UDID=${1:-$(xcrun simctl list devices booted | grep -Eo '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}' | head -1)}
if [ -z "$UDID" ]; then
  echo "没有指定模拟器 UDID，也没有已启动的模拟器：传 udid 参数，或先 xcrun simctl boot <udid>" >&2
  exit 2
fi
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FUSHI="$(cd "$HERE/../.." && pwd)"
TAPPER_DIR="$HERE/ios_touch_tapper"
TEST=${TEST:-integration_test/ios_popup_real_touch_itest.dart}
TAG=${TAG:-ios-touch}
TAP_DIR=${TAP_DIR:-/tmp/fushi-$TAG}
LOG_DIR=${LOG_DIR:-$HOME/dev}
SHOTS=${SHOTS:-$LOG_DIR/$TAG-shots}
ITEST_LOG="$LOG_DIR/$TAG-itest.log"
TAPPER_LOG="$LOG_DIR/$TAG-tapper.log"

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b 2>&1 | tail -1
# 显示器熄屏会让模拟器里的 WKWebView 判 hidden、rAF 冻结；唤醒一下。
caffeinate -u -t 2 || true
xcrun simctl uninstall "$UDID" app.fushi.reader 2>/dev/null || true
pkill -f "test-without-building -xctestrun.*TouchTapper" 2>/dev/null || true

TAPRUN="$(ls "$TAPPER_DIR"/dd/Build/Products/TouchTapper_iphonesimulator*.xctestrun 2>/dev/null | grep -v '/run.xctestrun' | head -1)"
if [ -z "$TAPRUN" ]; then
  (cd "$TAPPER_DIR" && xcodegen generate >/dev/null && xcodebuild build-for-testing \
    -project TouchTapper.xcodeproj -scheme TouchTapper -destination "id=$UDID" \
    -derivedDataPath "$TAPPER_DIR/dd" 2>&1 | grep -E "error|BUILD")
  TAPRUN="$(ls "$TAPPER_DIR"/dd/Build/Products/TouchTapper_iphonesimulator*.xctestrun 2>/dev/null | grep -v '/run.xctestrun' | head -1)"
fi
[ -n "$TAPRUN" ] || { echo "tapper 编不出来（xcodegen 在 PATH 吗？）" >&2; exit 2; }

mkdir -p "$TAP_DIR" "$SHOTS" "$LOG_DIR"
rm -f "$TAP_DIR"/* "$SHOTS"/*.png "$ITEST_LOG" "$TAPPER_LOG"

( cd "$FUSHI" && flutter test "$TEST" -d "$UDID" --no-pub > "$ITEST_LOG" 2>&1; echo "RUN_END rc=$?" >> "$ITEST_LOG" ) &
FT=$!

for _ in $(seq 1 450); do
  grep -q "Xcode build done\|Could not build\|RUN_END" "$ITEST_LOG" 2>/dev/null && break
  sleep 2
done
# 副本必须与原文件同目录：xctestrun 里的路径相对 __TESTROOT__。
COPY="$(dirname "$TAPRUN")/run.xctestrun"
cp "$TAPRUN" "$COPY"
plutil -replace "TouchTapperUITests.EnvironmentVariables.TAP_DIR" -string "$TAP_DIR" "$COPY"
plutil -replace "TouchTapperUITests.EnvironmentVariables.TAPPER_SECONDS" -string "1500" "$COPY"
( xcodebuild test-without-building -xctestrun "$COPY" -destination "id=$UDID" \
    -only-testing:TouchTapperUITests/TouchTapperTests/testTapLoop > "$TAPPER_LOG" 2>&1 ) &
TP=$!

( i=0; while kill -0 $FT 2>/dev/null; do
    L=$(grep -a "\[ios-touch\] TAP " "$ITEST_LOG" 2>/dev/null | tail -1 | sed 's/.*\[ios-touch\] TAP //')
    if [ -n "$L" ] && [ "$L" != "$(cat "$TAP_DIR/req" 2>/dev/null)" ]; then
      echo "$L" > "$TAP_DIR/req.tmp" && mv "$TAP_DIR/req.tmp" "$TAP_DIR/req"
      sleep 1.5
      xcrun simctl io "$UDID" screenshot "$SHOTS/t$(printf %03d $i).png" >/dev/null 2>&1
      i=$((i+1))
    fi
    sleep 0.2
  done ) &
BR=$!

# flutter test 在用例失败后偶尔不退出（app 侧还挂着）：见到结论行或用例 [E] 行 20 秒后收掉整棵进程树。
killtree() { for c in $(pgrep -P "$1"); do killtree "$c"; done; kill "$1" 2>/dev/null; }
while kill -0 $FT 2>/dev/null; do
  if grep -q "All tests passed\|Some tests failed\| \[E\]$" "$ITEST_LOG" 2>/dev/null; then
    sleep 20
    kill -0 $FT 2>/dev/null && { echo "flutter test 未自行退出，收掉进程树" >> "$ITEST_LOG"; killtree $FT; }
    break
  fi
  sleep 2
done
wait $FT 2>/dev/null
grep -q "RUN_END" "$ITEST_LOG" || { grep -q "All tests passed" "$ITEST_LOG" && echo "RUN_END rc=0" >> "$ITEST_LOG" || echo "RUN_END rc=1" >> "$ITEST_LOG"; }
kill $BR 2>/dev/null
pkill -f "test-without-building -xctestrun.*TouchTapper" 2>/dev/null
kill $TP 2>/dev/null
echo "=== tapper"; LC_ALL=C grep -a "\[touchtap\]\|unexpected exit" "$TAPPER_LOG" | tail -20 | cut -c1-200
echo "=== test"; grep -a "popup-touch\|ios-touch\|EXCEPTION\|Expected\|Actual\|Which\|reason\|All tests\|Some tests\|RUN_END" "$ITEST_LOG" | tail -80 | cut -c1-600
echo "shots: $(ls "$SHOTS" | wc -l) in $SHOTS"
grep -q "RUN_END rc=0" "$ITEST_LOG"
