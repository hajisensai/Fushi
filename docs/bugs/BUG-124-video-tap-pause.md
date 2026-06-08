## BUG-124 · 视频点击屏幕不暂停
- **报告**：2026-06-08（用户：点击屏幕也无法暂停 / Windows 桌面）
- **真实性**：✅ 真 bug（media_kit 桌面控制条默认值未启用），根因 `video_hibiki_page.dart:1217 _desktopControlsTheme`。

### 根因（真实代码路径取证）
media_kit `media_kit_video-2.0.1/lib/media_kit_video_controls/src/controls/material_desktop.dart:188` 的 `MaterialDesktopVideoControlsThemeData.playAndPauseOnTap` **默认 `false`**——`material_desktop.dart:611-627` 的 GestureDetector `onTapDown` 仅当该值为 true 才 `playOrPause()`。本项目 `_desktopControlsTheme` 从没设过它 → 桌面单击画面毫无反应。字幕字符点击在更上层 `VideoSubtitleOverlay` 的 `HitTestBehavior.opaque` GestureDetector 独立处理、不冒泡到控制条，故启用后不冲突。

### 修复
`_desktopControlsTheme` 加 `playAndPauseOnTap: true`。

- **[x] ① 已修复** — `video_hibiki_page.dart _desktopControlsTheme` 加 `playAndPauseOnTap: true`。
- **[x] ② 已加自动化测试** — `test/pages/video_subtitle_fixes_guard_test.dart`（桌面控制主题含 `playAndPauseOnTap: true` 守卫）。
- **备注**：media_kit 无 headless，真机点击暂停待用户复验。
