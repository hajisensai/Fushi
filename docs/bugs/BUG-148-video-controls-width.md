## BUG-148 · 视频底栏压缩不应只限定移动端

- **报告**：2026-06-09。用户指出“按宽度判断”不应限定为移动端：电脑端窗口变窄时同样可能出现底栏按钮挤出屏幕，视频底栏应该按实际可用宽度压缩，而不是按手机/电脑平台分支。
- **真实性**：是 bug。根因在 `hibiki/lib/src/pages/implementations/video_hibiki_page.dart:1242` 的 `_desktopControlsTheme` 和 `:1358` 的 `_mobileControlsTheme`：media_kit 桌面/移动 controls 是互斥两套主题，BUG-147 只在移动主题内新增 `roomyBottomBar`，桌面主题仍固定塞入 `Icons.replay_10` / `Icons.forward_10`。因此电脑窄窗口不会跟手机窄屏一样压缩底栏，平台分支掩盖了真正的宽度约束。
- **[x] ① 已修复** - 新增 `_hasRoomyVideoBottomBar()` 共用谓词，按 `MediaQuery.of(context).size.width >= 600` 判断实际可用宽度；桌面 `_desktopControlsTheme` 和移动 `_mobileControlsTheme` 都通过同一个 `roomyBottomBar` gate 包住 `-10s / +10s`。窄宽度只保留时间、上一句、播放、下一句、全屏；宽度足够时桌面和移动端都保留 10 秒后退/前进。
- **[x] ② 已加自动化测试** - `hibiki/test/pages/video_mobile_controls_guard_test.dart` 守住桌面/移动两套 `bottomButtonBar` 都必须使用 `_hasRoomyVideoBottomBar()`，并且 `Icons.replay_10` / `Icons.forward_10` 只能在 `if (roomyBottomBar)` 分支内出现；测试先红后绿，确认捕获了桌面端遗漏。
- **备注**：headless 测试只能守住源码布局分支；仍建议分别用桌面窄窗口、桌面宽窗口、手机竖屏、手机横屏肉眼复测控制条是否符合预期。
