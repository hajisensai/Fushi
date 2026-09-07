## BUG-2229 · 视频资源缺失态没有返回入口，进入后无法退出
- **报告**：2026-09-07（用户：截图 —— Windows 打开一集已不在磁盘上的视频，页面只有「重新导入」一个按钮，退不出去）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/pages/implementations/video_fushi_page.dart:7548`（`_buildMissingResourceBody`）。
  视频页**有意不挂 AppBar**（BUG-102：退出/标题/剧集导航全部并进 media_kit controls 的视频内顶栏，避免两条顶栏），
  而资源缺失态在 `controller.load` 之前就短路了 —— `_controller` 恒为 null ⇒ 视频内顶栏根本没挂载。
  同一 `_buildScaffold` 的另外两个非播放态都记得自带出口：加载态 `_buildLoadingBody` 给了 `VideoLoadingOverlay.onBack`，
  失败态 `_buildFailedBody` 给了「返回」按钮；唯独缺失态只给了「重新导入 / 删除」两个**修复动作**，没有退出动作。
  桌面端又没有系统返回键（`PopScope` 拦的是系统 back），于是 Windows 上进入即死路。
  `_promptMissingResource` 的注释里写的「可重连磁盘后**退页重进**」，实际上没有可退的入口。
  截图那一例还更糟：条目 `canDelete == false`（播放列表/远端），连「删除」都不显示，整页只剩一个按钮。
- **[x] ① 已修复** — `_buildMissingResourceBody` 的按钮组补一颗「返回」`TextButton`，走与失败态/加载态同一条
  `_handleBackOrExit()`（同样 flush 播放位置、先清浮层栈再 pop）。文案复用既有通用 key `t.back`（17 语言齐全，
  不新增 key、不产生翻译欠账）。
- **[x] ② 已加自动化测试** — `fushi/test/pages/video_missing_resource_test.dart`
  新增 `missing state offers a working back button (BUG-2229)`：把视频页 push 在占位根路由之上（这样 pop 有东西可退），
  驱动真实缺失链落到缺失态，关掉首帧提示对话框，断言正文里有「返回」按钮，**并点击它验证真的退回了占位路由**。
  变异实测：删掉那颗按钮后该用例红在 `backButton` 断言（`FLUTTER TEST VERDICT: FAILED`），恢复后
  `FLUTTER TEST VERDICT: PASSED - 2 tests ran`。
- **备注**：只加出口，不动缺失判据、不动 `_promptMissingResource` 的对话框选项，行为向后兼容。
