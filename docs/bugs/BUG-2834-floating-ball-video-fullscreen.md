## BUG-2834 · 视频全屏时悬浮球退回其它页面按钮
- **报告**：2026-10-01（用户：哈吉千歳，QQ 群截图：窗口模式下悬浮球是视频那组按钮，全屏后只剩关闭 / 查词 / 剪贴板）
- **真实性**：✅ 真 bug。视频页只在窗口侧 Scaffold 里挂了一份 `FloatingBallScene`（`fushi/lib/src/pages/implementations/video_fushi_page.dart` `_buildScaffold` → `_buildVideoFloatingBallScene`）；全屏是 `_pushNeutralizedVideoFullscreen`（`video_fushi/fullscreen.part.dart`）压到根导航器上的独立 `PageRouteBuilder`，视频页路由随之不是当前路由，`FloatingBallSceneRegistry.current`（`floating_ball/floating_ball_scene.dart`）只认当前路由上的场景，于是退回 `FloatingBallScope.general`（设置里「其它页面」那组）。
- **[x] ① 已修复** — 全屏路由的 `pageBuilder` 内容外包一份 `_buildVideoFloatingBallScene(playerController, child: …)`（该方法加 `child` 透传），全屏期间当前路由上就有同源同按钮的视频场景；退出全屏路由卸载、登记随之撤销。
- **[x] ② 已加自动化测试** — `fushi/test/floating_ball/video_fullscreen_floating_ball_scene_test.dart`（注册表行为：根导航器压全屏路由后仍是视频场景 + 源码守卫：全屏 `pageBuilder` 必须包视频场景）。
- **备注**：未在真 app 全屏下复测像素；判据是注册表「当前路由」语义，已由 widget 测试覆盖。
