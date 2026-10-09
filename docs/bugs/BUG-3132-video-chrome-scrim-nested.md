## BUG-3132 · 视频库页滚动时内容透到顶栏与页签下面
- **报告**：2026-10-09（用户：哈吉千歳，应用内反馈 m53uFSTe5O「视频页顶部显示背景透明了」，Windows）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/utils/components/fushi_floating_chrome.dart` 的 `_FushiFloatingChromeOverlayState.build`：顶部遮罩只由最外层工具区画，且 `fadeExtent = outer + shown * min(_chromeHeight, kFushiTopScrimChromeReach=40) + 32`——只伸进外壳页签胶囊 40 px；页面自己的工具行（视频库的页头 / 搜索行 / 标签行 / 提醒横幅，嵌套的 `FushiFloatingChromeOverlay`）明确「不画第二层遮罩」，于是内容一滚到这几行背后就整片透出封面。书架 / 漫画库同一个共享组件（`MediaLibraryShell` + 页面嵌套工具区），同样受影响。
- **[x] ① 已修复** — 本 PR：嵌套工具区把自己此刻的可见下沿（全局坐标，跟弹簧逐帧走，隐藏的保活分区不报）报给外层；最外层遮罩的不透明段（肩）盖到「外壳 + 所有嵌套工具行」的可见下沿，再往下 32 px 柔和渐隐。工具区收起时遮罩随弹簧收回顶边，不会回到 2026-10-06 那种两三百 px 常驻白底。共享组件层修，书架 / 漫画库 / 视频库一起生效。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/fushi_floating_chrome_library_test.dart`（外壳 + 嵌套工具区真实叠法：内容滚到底下时遮罩不透明段 ≥ 嵌套工具行下沿；收起后遮罩收回）；`fushi/test/build/floating_top_scrim_guard_test.dart` 守卫随新语义更新。
- **备注**：像素对照见 PR（`video_library_chrome_preview_test.dart` 出的 before / after PNG）。真机 Windows 视频库页尚未肉眼复测。
