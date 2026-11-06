## BUG-4130 · 视频顶栏「返回」跳转按钮在圆胶囊里叠出方块，像两颗按钮
- **报告**：2026-11-05（开发者：应用内反馈 ekVmlGuze5，Windows 3.3.0-debug.23866；「按钮是两个按钮叠加的」，截图是 ↶ 图标：深色圆胶囊里套一块方圆角色块）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/video_fushi/jump_history.part.dart:288`（develop 9eae475329）：跳转记录的返回 / 前进组自己是一枚 `VideoControlBar` 浮动胶囊（`clusterStyle: _m3eFloatingBarStyle`，胶囊圆角 = 高 / 2），里面的按钮又用 `VideoM3eButtonTone.secondary`；`VideoM3eIconButton` 对非中性档按开关「开」态画常驻 secondaryContainer + 0.3×直径的方圆角（`fushi/lib/src/media/video/video_m3e_chrome.dart:455`）。单按钮胶囊里叠一块方圆角色块，看起来就是两颗按钮。返回 / 前进不是开关。
- **[x] ① 已修复** — 按钮改中性档（透明底，悬停 / 按压才出状态层），胶囊即按钮外观，与「顶栏纯图标」的定稿一致。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_jump_history_test.dart`「返回 / 前进按钮是中性档，不在胶囊里再叠 tonal 色块」（源码守卫：组内不得出现 secondary / tertiary / tonal / selected）。
- **备注**：反馈标题「反馈按钮」按截图图标与日志（视频播放中）判定为跳转记录的「返回」按钮。未在真机复测。
