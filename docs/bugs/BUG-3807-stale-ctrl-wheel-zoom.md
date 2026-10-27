## BUG-3807 · Ctrl 抬起落在 WebView2 后字幕列表滚轮变成缩放字号
- **报告**：2026-10-24（用户：反馈 TpKspDUst7，Windows，视频字幕 / 收藏句列表滚轮偶尔变成缩放字号，按一下 Ctrl 恢复）
- **真实性**：✅ 真 bug。`_handleZoomWheel` 只读 `HardwareKeyboard.instance.isControlPressed`（`fushi/lib/src/media/video/video_subtitle_jump_panel.dart:1101`），该缓存只由 Flutter 收到的 KeyEvent 维护；Ctrl 抬起落在 WebView2 / 别的窗口时卡在「按下」，`_zoomModifierHeld` 同时把列表物理切成禁滚，字号还被持久化。
- **[x] ① 已修复** — 新增 `isZoomModifierPressed()`（`fushi/lib/src/shortcuts/platform_modifier_state.dart`）：缓存说按着时在 Windows 上以 `GetAsyncKeyState` 为准；字幕列表滚轮改用它，并在发现卡住时解除 `_zoomModifierHeld`。提交见分支 `claude/feedback-system-fix-d0ccae`。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_subtitle_jump_panel_test.dart`（缓存 Ctrl 卡住但平台说没按 → 不缩放；真按着 → 照常放大）。
- **备注**：其它 Ctrl + 滚轮读缓存的地方（如 srs 浏览预览、阅读器）同理可换用该函数，本条只改了反馈路径；未真机复测。
