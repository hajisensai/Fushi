#!/usr/bin/env bash
# BUG-2493 iOS 模拟器实测编排（在装了 Xcode 的 Mac 上跑，仓库已 checkout 到待测提交）。
#
#   bash fushi/integration_test/support/fake_ankimobile/run_sim_itest.sh [udid]
#
# 做四件事：
#   1. 把 FakeAnkiMobile 替身编好、卸载重装进模拟器（请求计数归零），并清空系统剪贴板
#      （上一轮没被消费的 net.ankimobile.json 会一直留着，把「没写」形态污染成「写了」）；
#   2. 卸载 Fushi 拿干净容器（别的分支留下的库 schema 可能更新，裸跑撞 downgrade）；
#   3. 后台 `flutter test integration_test/ios_ankimobile_info_return_itest.dart -d <udid>`；
#   4. 等它的 Xcode 构建结束后，再起 ios_alert_tapper（XCUITest）自动放行系统弹窗
#      ——「"Fushi" 想要打开 "FakeAnki"」与「允许粘贴」。必须等构建结束：flutter 的
#      xcodebuild 会把同一模拟器上正在跑的 XCUITest 会话打断（runner unexpected exit）。
#      ssh 起的进程没有辅助功能授权，CGEvent / AppleScript 投不进 Simulator.app；
#      idb-companion 又要 Xcode 27；XCUITest 走模拟器内部 AX 通道不受这两条限制。
# 每 2 秒抓一张真屏到 $SHOTS，测试结束后打印 tapper 点了几次、FakeAnki 的最后动作。
set -u
export LANG=en_US.UTF-8
UDID=${1:-969CB3A4-036B-4494-824E-087A427F3C10}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FUSHI="$(cd "$HERE/../../.." && pwd)"
TAPPER_DIR="$FUSHI/integration_test/support/ios_alert_tapper"
SHOTS=${SHOTS:-$HOME/dev/ios-shots/anki}
LOG_DIR=${LOG_DIR:-$HOME/dev}
ITEST_LOG="$LOG_DIR/anki-itest.log"
TAPPER_LOG="$LOG_DIR/anki-tapper.log"

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b 2>&1 | tail -1

bash "$HERE/build_install.sh" "$UDID" 2>&1 | tail -1
xcrun simctl uninstall "$UDID" app.fushi.reader 2>/dev/null || true
xcrun simctl uninstall "$UDID" app.fushi.fakeankimobile 2>/dev/null || true
xcrun simctl install "$UDID" "$HERE/build/FakeAnkiMobile.app"
printf '' | xcrun simctl pbcopy "$UDID"
pkill -f "test-without-building -xctestrun" 2>/dev/null || true

# 放行器只需编一次（xcodegen 生成工程 → build-for-testing → xctestrun）。
TAPRUN="$(ls "$TAPPER_DIR"/dd/Build/Products/AlertTapper_iphonesimulator*.xctestrun 2>/dev/null | head -1)"
if [ -z "$TAPRUN" ]; then
  if ! command -v xcodegen >/dev/null 2>&1; then
    echo "xcodegen 不在 PATH（brew install xcodegen）；没有它放行不了系统弹窗，测试会卡在「允许粘贴」。" >&2
  else
    (cd "$TAPPER_DIR" && xcodegen generate >/dev/null && xcodebuild build-for-testing \
      -project AlertTapper.xcodeproj -scheme AlertTapper -destination "id=$UDID" \
      -derivedDataPath "$TAPPER_DIR/dd" 2>&1 | grep -E "error|BUILD")
    TAPRUN="$(ls "$TAPPER_DIR"/dd/Build/Products/AlertTapper_iphonesimulator*.xctestrun 2>/dev/null | head -1)"
  fi
fi

mkdir -p "$SHOTS" "$LOG_DIR" && rm -f "$SHOTS"/*.png "$ITEST_LOG" "$TAPPER_LOG"
( trap "" HUP; i=0; while true; do
    xcrun simctl io "$UDID" screenshot "$SHOTS/s$(printf %03d $i).png" >/dev/null 2>&1
    i=$((i+1)); sleep 2
  done ) &
SHOT=$!

( cd "$FUSHI" && flutter test integration_test/ios_ankimobile_info_return_itest.dart -d "$UDID" --no-pub > "$ITEST_LOG" 2>&1 ) &
FT=$!

ALLOW=""
if [ -n "$TAPRUN" ]; then
  for _ in $(seq 1 150); do
    grep -q "Xcode build done\|Could not build" "$ITEST_LOG" 2>/dev/null && break
    sleep 2
  done
  # 副本必须与原文件同目录：xctestrun 里的路径相对 __TESTROOT__（所在目录）。
  TAPCOPY="$(dirname "$TAPRUN")/run.xctestrun"
  cp "$TAPRUN" "$TAPCOPY"
  plutil -replace "AlertTapperUITests.EnvironmentVariables.TAPPER_SECONDS" -string "900" "$TAPCOPY"
  ( xcodebuild test-without-building -xctestrun "$TAPCOPY" -destination "id=$UDID" > "$TAPPER_LOG" 2>&1 ) &
  ALLOW=$!
fi

wait $FT
RC=$?
grep -v "^\s*$" "$ITEST_LOG" | tail -40
kill $SHOT 2>/dev/null
if [ -n "$ALLOW" ]; then pkill -f "test-without-building -xctestrun" 2>/dev/null; kill $ALLOW 2>/dev/null; fi
echo "tapper: $(LC_ALL=C grep -a -c "\[tapper\] tapped" "$TAPPER_LOG" 2>/dev/null) taps"
LC_ALL=C grep -a "\[tapper\] tapped\|unexpected exit" "$TAPPER_LOG" 2>/dev/null | tail -8 | cut -c1-160
FAKEPREFS="$(xcrun simctl get_app_container "$UDID" app.fushi.fakeankimobile data 2>/dev/null)/Library/Preferences/app.fushi.fakeankimobile.plist"
echo "fakeanki prefs: $(plutil -p "$FAKEPREFS" 2>/dev/null | tr -d '\n' | cut -c1-300)"
echo "shots: $(ls "$SHOTS" | wc -l) in $SHOTS"
echo "flutter test exit=$RC"
exit $RC
