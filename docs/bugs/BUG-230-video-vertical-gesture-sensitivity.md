## BUG-230 · 视频亮度/音量竖滑手势太敏感（TODO-172）
- **报告**：2026-06-12（用户：）
- **真实性**：✅ 真 bug。media_kit `MaterialVideoControlsThemeData.verticalGestureSensitivity` 默认 100（满量程仅需约 100px 竖向拖动 → 太敏感），Hibiki 的 `_mobileControlsTheme` 构造主题时未覆盖该参数。公式 `value -= delta.dy / verticalGestureSensitivity`（值越大越不敏感）。根因 `hibiki/lib/src/pages/implementations/video_hibiki_page.dart:_mobileControlsTheme`（MaterialVideoControlsThemeData(...) 缺 verticalGestureSensitivity）。
- **[x] ① 已修复** — `video_hibiki_page.dart` 新增静态常量 `_videoVerticalGestureSensitivity = 320.0`（灵敏度降到约 1/3），传入 `_mobileControlsTheme` 的 `MaterialVideoControlsThemeData(verticalGestureSensitivity: _videoVerticalGestureSensitivity)`。桌面 `_desktopControlsTheme` 无此手势不改。提交：（见本轮 commit）
- **[x] ② 已加自动化测试** — 源码守卫 `hibiki/test/pages/video_double_tap_seek_guard_test.dart`（断言 `_videoVerticalGestureSensitivity` 常量存在且 > 100、`_mobileControlsTheme` 传入 `verticalGestureSensitivity:`）。
- **备注**：S 级。仅移动端有该竖滑手势（亮度/音量），桌面诚实降级不改。
