#!/bin/bash
# gamepad-nav.sh — 用"手柄/D-pad"按键事件驱动 Hibiki，零坐标点击
# 用法: ./gamepad-nav.sh [device-serial]
#
# 原理: Hibiki 的通用焦点导航层复用 Flutter 内建焦点系统：
#   - KEYCODE_DPAD_* (方向键/手柄十字键) → 移动焦点 (DirectionalFocusIntent)
#   - KEYCODE_BUTTON_A / DPAD_CENTER     → 激活当前焦点控件 (ActivateIntent)
#   - KEYCODE_BUTTON_B                   → 返回/关闭 (HibikiPopIntent → maybePop)
# 因此整套 UI 都能用离散按键操作，不依赖屏幕分辨率与坐标。
#
# 本脚本启动应用并发送一段导航序列，用 uiautomator dump 的 focused="true"
# 展示焦点确实在移动（证明 UI 可被手柄遍历）。

ADB="D:/android_sdk/platform-tools/adb.exe"
SERIAL="${1:-}"
PKG="app.hibiki.reader"

ADB_CMD="$ADB"
if [ -n "$SERIAL" ]; then
  ADB_CMD="$ADB -s $SERIAL"
fi

key() { $ADB_CMD shell input keyevent "$1" >/dev/null 2>&1; }

focused_element() {
  $ADB_CMD shell uiautomator dump //sdcard/_gp_ui.xml >/dev/null 2>&1
  $ADB_CMD shell cat //sdcard/_gp_ui.xml 2>/dev/null \
    | tr '>' '>\n' \
    | grep 'focused="true"' \
    | grep -oP '(content-desc|text|class)="[^"]*"' \
    | tr '\n' ' '
  $ADB_CMD shell rm //sdcard/_gp_ui.xml >/dev/null 2>&1
}

echo "=== gamepad-nav: 唤醒并启动 $PKG ==="
$ADB_CMD shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
$ADB_CMD shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep 6

echo "=== 初始焦点 ==="
echo "  before: $(focused_element)"

echo "=== 发送方向键序列（移动焦点，零点击）==="
for k in KEYCODE_DPAD_DOWN KEYCODE_DPAD_RIGHT KEYCODE_DPAD_DOWN KEYCODE_DPAD_RIGHT; do
  key "$k"
  sleep 0.6
  echo "  $k → focus: $(focused_element)"
done

echo "=== BUTTON_A 激活当前焦点控件 ==="
key KEYCODE_BUTTON_A
sleep 2
echo "  after A: $(focused_element)"

echo "=== BUTTON_B 返回 ==="
key KEYCODE_BUTTON_B
sleep 1.5
echo "  after B: $(focused_element)"

echo
echo "完成。如果各步 focus 行内容发生变化，说明 UI 已可被手柄/键盘离散按键遍历与操作。"
echo "数据库级断言请配合: $ADB_CMD shell run-as $PKG sqlite3 files/hibiki.db '<query>'"
