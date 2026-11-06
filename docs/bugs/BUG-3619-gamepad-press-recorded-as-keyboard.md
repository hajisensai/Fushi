## BUG-3619 · Android 手柄按键在键盘分段录成键盘绑定，绕过手柄冲突检测
- **报告**：2026-10-19（用户：应用内反馈 pow-k_jEmW，Android / Xbox 手柄）
- **真实性**：✅ 真 bug。Android 上手柄按键（LB = `gameButtonLeft1`、手柄来源的十字键 = `arrowUp` + deviceType joystick）是 Flutter `KeyEvent`。快捷键设置的两个**键盘**捕获入口都不看事件来源，原样存成键盘绑定：
  - 列表视图行内录制：`fushi/lib/src/pages/implementations/shortcut_settings/shortcut_browser.part.dart:533-541`（`_onRecordKey` 只在手柄分段才走 `GamepadButton.fromKeyEvent`，键盘分段直接 `InputBinding(key: gameButtonLeft1)`）；
  - 完整编辑对话框键盘捕获区：`fushi/lib/src/pages/implementations/shortcut_settings/binding_edit_dialog.part.dart:394-421`（`_onKeyEvent`）。
  后果：冲突检测走 `hasKeyboardConflict` 只扫键盘通道，看不到别的动作上的手柄 LB → **不提示重复**；手柄键位图（`ReverseBindingIndex` 只读手柄通道）不显示它，但视频页 `_resolveVideoKeyboardAction` 照样被 LB 的 KeyEvent 命中——反馈里「键位图里把 LB 全取消了，按 LB 还是后退」与「十字键被识别成键盘 arrowUp」都是同一个根因。按键反查（`_onKeySearchKey`）早已按 `fromKeyEvent` 分流，只有录制路径漏了。
- **[x] ① 已修复** — 两个键盘捕获入口先过 `GamepadButton.fromKeyEvent`：手柄来的按键改投手柄通道并走手柄冲突检测（行内录制切到手柄分段、按追加录入，不冲掉键盘分段里看不到的已有手柄绑定；对话框复用 `_addGamepad` 三段式）；动作没有手柄通道时不录。桌面轮询路径（`GamepadButtonIntent`）在非手柄分段也按同一规则处理。
- **[x] ② 已加自动化测试** — `fushi/test/shortcuts/shortcut_gamepad_binding_conflict_display_test.dart`（键盘分段按 LB 出手柄冲突条且不写键盘通道 / 空闲 LB 追加到手柄通道并切分段 / joystick 来源十字键录成 dpadUp / 键盘来源仍录键盘 / 对话框键盘捕获区按 LB 进手柄草稿）。
- **备注**：待真机复测（Android + Xbox 手柄）。十字键的手柄 / 键盘之分依赖引擎按 `KeyEvent.getSource()` **精确等值**推 deviceType（`KeyEmbedderResponder.java`：`SOURCE_JOYSTICK`/`SOURCE_GAMEPAD`/`SOURCE_DPAD` 才不是 keyboard）：HAT 轴经 `ViewRootImpl` 合成的十字键 source 沿用摇杆 → joystick，能区分；若某手柄内核把十字键报成 `BTN_DPAD_*` 键（source 为 KEYBOARD|DPAD|GAMEPAD 组合值），引擎会落 keyboard，Dart 侧无从区分。存量里已被存成键盘通道的 `gameButton*` 绑定本次未迁移。
