## BUG-1335 · Mihon 漫画详情页路由触发布局断言
- **报告**：2026-07-29（用户：点进 Raw Otaku 漫画后出现 `debugNeedsLayout` 红屏）
- **真实性**：✅ 真 bug。持久错误日志的第一现场是
  `hibiki/lib/src/pages/implementations/texthooker_page.dart:432-441`：
  保活的 `TexthookerPage` 在 `TickerMode` 依赖变化触发
  `didChangeDependencies()` 时，仍处于 widget build 阶段，却同步调用根
  `OverlayEntry.markNeedsBuild()`。根 Overlay 不是当前正在构建元素的后代，
  Flutter 因而先抛 `setState() or markNeedsBuild() called during build`，
  随后 dirty/layout 队列失序并连锁成截图里的
  `RenderObjectWithLayoutCallbackMixin.scheduleLayoutCallback`
  `debugNeedsLayout` 断言。Mihon 详情请求、章节请求和图片请求本身均已闭环；
  漫画路由只是触发后台保活页依赖变化的入口。
- **[x] ① 已修复** — `f567588b2`：`_schedulePopupOverlayRebuild()` 合并
  TickerMode 可见性变化，在当前帧 build/layout 完成后才重建根 Overlay；
  回调重新核验 `mounted`、entry 存在且已挂载，保持隐藏 tab 浮层 inert
  语义，同时不再跨树构建期标脏。
- **[x] ② 已加自动化测试** — `f567588b2`：
  `hibiki/test/pages/texthooker_page_test.dart:279` 先挂载真实根
  `OverlayEntry`，再切换 `TickerMode`，修复前稳定复现与用户日志相同的第一异常，
  修复后通过；`hibiki/test/media/manga/mihon_source_browse_page_test.dart:64`
  另覆盖来源网格 → 详情路由 → 486 章节加载。
- **备注**：两组完整 Widget 测试共 16 项通过；Windows debug 构建成功。
  修复版真实应用的 inspector 树确认已走通
  `MihonSourceBrowsePage → MihonMangaDetailPage → MihonChapterReaderPage →
  MihonOnlineReaderPage`，期间 `C:\文档\error_log.txt` 时间和大小均未变化。
  本机 Flutter 3.44 的 `flutter analyze` 工具自身因 LSP JSON 响应截断退出，
  未产生代码诊断；编译由 Windows debug build 完成校验。
