## BUG-3132 · 视频库页滚动时内容透到顶栏与页签下面
- **报告**：2026-10-09（用户：哈吉千歳，应用内反馈 m53uFSTe5O「视频页顶部显示背景透明了」，Windows）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/utils/components/fushi_floating_chrome.dart` 的 `_FushiFloatingChromeOverlayState.build`：顶部遮罩只由最外层工具区画，且 `fadeExtent = outer + shown * min(_chromeHeight, kFushiTopScrimChromeReach=40) + 32`——只伸进外壳页签胶囊 40 px；页面自己的工具行（视频库的页头 / 搜索行 / 标签行 / 提醒横幅，嵌套的 `FushiFloatingChromeOverlay`）明确「不画第二层遮罩」，于是内容一滚到这几行背后就整片透出封面。书架 / 漫画库同一个共享组件（`MediaLibraryShell` + 页面嵌套工具区），同样受影响。
- **[x] ① 已修复** — 本 PR：遮罩的**位置和范围**跟着实际可见的工具区走，风格沿用 2026-10-06 定的「短渐隐、不垫整块底色」（用户 2026-10-09 确认反馈说的是位置不对，不是要实底）。视口顶边是页面底色，随即缓降到半透明薄纱 `kFushiTopScrimOverlayOpacity`（0.72），薄纱铺在外壳页签胶囊与所有嵌套工具行（页头 / 搜索 / 标签行）背后，最后一行工具栏下方再 32 px 渐隐到 0；工具区收起时随弹簧一起收回。外壳与嵌套层各画自己那段（嵌套工具行住在外壳内容层里，外壳的遮罩若一路盖下来会把它们本身压成半透明），只有最深一层负责渐隐；嵌套层把可见下沿报给外层用来判断「下面还有没有工具行」。共享组件层修，书架 / 漫画库 / 视频库一起生效。第一版（肩段 1.0→0.82 铺满整个工具区，接近实底）已被取代。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/fushi_floating_chrome_library_test.dart`（外壳 + 嵌套工具区真实叠法：内容滚到底下时遮罩不透明段 ≥ 嵌套工具行下沿；收起后遮罩收回）；`fushi/test/build/floating_top_scrim_guard_test.dart` 守卫随新语义更新。
- **备注**：像素对照见 PR（`video_library_chrome_preview_test.dart` 出的 before / after PNG）。真机 Windows 视频库页尚未肉眼复测。
