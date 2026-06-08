## BUG-145 · 手机视频控制条取消三点并压缩底栏按钮

- **报告**：2026-06-08。用户反馈手机视频未放大时点不到右上角三个点，顶栏按钮总数不多，应取消三点；底栏按钮太多，已经挤出屏幕。
- **真实性**：是 bug。根因在 `hibiki/lib/src/pages/implementations/video_hibiki_page.dart:1358` 的 `_mobileControlsTheme`：BUG-134 后移动端顶栏在窄屏把字幕/音轨/设置等入口藏到 `Icons.more_vert`，但这个入口本身成为手机未放大状态下点不到的小目标；同一移动端 `bottomButtonBar` 还额外塞入 `Icons.replay_10`、`Icons.forward_10`、前后句、播放和全屏，压缩了底栏触控空间。
- **[x] ① 已修复** - `_mobileControlsTheme` 取消移动端三点菜单和 `_showMobileMoreMenu` 分支，顶栏直接保留截图、字幕源、音轨和设置；底栏移除 10 秒后退/前进，只保留时间、上一句、播放、下一句、全屏。
- **[x] ② 已加自动化测试** - `hibiki/test/pages/video_mobile_controls_guard_test.dart` 守住移动端顶栏不再包含 `Icons.more_vert` / `_showMobileMoreMenu` / 宽度分支，并守住截图、字幕源、音轨、设置仍直接在顶栏；底栏不再包含 `Icons.replay_10` / `Icons.forward_10`，同时保留前后句、播放和全屏。
- **备注**：media_kit 播放器无法在 headless widget test 中真实复现手机触控命中，当前测试采用同类视频控制条源码守卫；仍建议在 Android 真机上复测未放大竖屏视频顶栏和底栏命中。
