## BUG-5414 · browser-page-fullscreen-caption-buttons
- **报告**：2026-11-24（用户：应用内反馈 WtYMwfPjpe，Windows「顶栏右上角的缩小放大关闭好像不会隐藏」，截图是内置浏览器里 YouTube 自己的全屏播放界面）
- **真实性**：✅ 真 bug。内置浏览器的网页全屏（站点全屏键被 `webBrowserFullscreenScript` 截成页内伪全屏）在 `fushi/lib/src/pages/implementations/fushi_web_browser_page.dart` `_applyFullscreenDisplay` → `_applySystemUi` 只调 `SystemChrome.setEnabledSystemUIMode(immersiveSticky)`，这在桌面是 no-op；浏览页从没告诉桌面自绘顶栏（`FushiDesktopTitleBar.setContentFullscreen`），浏览页又不是沉浸页（没上报 `FushiTitleBarColorScope`），所以标题行常显、窗口按钮组一直浮在全屏画面右上角。分诊初判指向的视频播放页（`video_fushi/fullscreen.part.dart` 的 runner 全屏、网页档 `_toggleWebWindowFullscreen`）都已登记 `setContentFullscreen`，不是这条路径。
- **[x] ① 已修复** — `fushi_desktop_title_bar.dart` 新增声明式 `FushiTitleBarContentFullscreenScope`（与 Reveal / DragBand scope 同一套「被整页盖住 / dispose 即撤回」骨架），浏览页 build 外层按前台标签页的 `fullscreen` 登记；`setContentFullscreen` 在构建期调用时把 notifier 发布推到帧尾（顶栏是页面祖先，构建中不能标脏它），命令式调用方不受影响。
- **[x] ② 已加自动化测试** — `fushi/test/pages/fushi_web_browser_shell_test.dart`「桌面自绘标题栏：网页全屏时窗口按钮随顶栏一起收起，退出 / 离开浏览页还原」。
- **备注**：网页全屏仍只铺满窗口、不把 OS 窗口切成真全屏（与现有设计「伪全屏五端一致」相同）；要不要像 Chrome 那样顺带窗口全屏是另一个取舍，未改。
