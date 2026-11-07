## BUG-4226 · collection-detail-open-eager-grid
- **报告**：2026-11-07（用户：录屏「漫画、视频系列、音乐播放器打开卡顿」）
- **真实性**：✅ 真 bug（视频合集详情页）。profile 构建 + 安装版数据拷贝复现（`fushi/integration_test/detail_open_perf_itest.dart`，《药屋少女》48 集）：推页后约 100～150 ms 详情数据到达，那一帧 build 57～91 ms，下一帧 raster 30～85 ms，正落在推页过渡中，与路由背景开关无关。根因之一：集卡网格 `FushiReorderableGrid` 是 `Stack` + 每格一个 `Positioned`，不在 sliver 里，48 张卡（含缩略图解码）同一帧全部 build / layout / paint（`fushi/lib/src/utils/components/fushi_reorderable_grid.dart` 旧 `build` 的 `for (int di …)` 无条件建格）。漫画作品页在真实数据上未复现（最长帧 <18 ms）；音乐播放页只有零星 13～30 ms raster 帧。
- **[x] ① 已修复** — 网格有纵向祖先 `Scrollable` 时只建「视口 ± 半屏」相交的行（`_rowsToBuild` / `_measureWindowRows`），滚动监听 + 绘制探针在帧末重量窗口，拖拽 / 触摸待命中的单元始终保留；无 `Scrollable` 时照旧全量。改后同一帧降到 32～75 ms（集卡 48→24）。剩余开销是整页内容量（约 21 ms build + 17 ms 段落排版 + GC），逐项无病态热点。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/fushi_reorderable_grid_test.dart`「viewport window」组：首帧只建视口附近、滚动补建并丢远行、不滚动的位移重量窗口、自动滚动越窗时拖拽单元保留、无 Scrollable 全量。
- **备注**：同一组件也用于视频库首页、游戏库、合集网格页、阅读历史、自定义字体页，条目多时同样受益。测速装置见 itest 文件头注释。
