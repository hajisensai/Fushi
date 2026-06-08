## BUG-147 · 手机视频宽屏底栏不应丢失10秒跳转

- **报告**：2026-06-09。用户指出上次把移动端底栏的 `-10s/+10s` 一刀切移除不合理；横屏、平板或宽屏移动端有足够空间，应按宽度判断，只有窄屏才压缩。
- **真实性**：是 bug。根因在 `hibiki/lib/src/pages/implementations/video_hibiki_page.dart:1358` 的 `_mobileControlsTheme`：BUG-145 修复手机窄屏按钮挤出时，把移动端 `bottomButtonBar` 的 `Icons.replay_10` / `Icons.forward_10` 完全删除，没有保留宽屏移动端可容纳完整控制条的分支。
- **[x] ① 已修复** - `_mobileControlsTheme` 新增 `roomyBottomBar = MediaQuery.of(context).size.width >= 600`，仅窄屏隐藏 10 秒后退/前进；宽屏、横屏、平板移动端保留 `-10s / +10s`。
- **[x] ② 已加自动化测试** - `hibiki/test/pages/video_mobile_controls_guard_test.dart` 守住移动端底栏必须存在 `roomyBottomBar` 宽度判断，并要求 `if (roomyBottomBar)` 分支内保留 `Icons.replay_10` / `Icons.forward_10`。
- **备注**：仍建议 Android 真机/模拟器分别复测竖屏未放大和横屏/宽屏视频控制条；headless 测试只能守住源码布局分支。
