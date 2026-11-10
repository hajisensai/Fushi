## BUG-4363 · 浏览页已装在线源整组非懒建：上千行全绘进合成树
- **报告**：2026-11-07（应用内崩溃报告 #E5IZOyVcbm，Android SM-A366B，3.3.0：进程在后台被杀前停在 `HomePage>BrowsePage`，空闲 `frames=0`，合成树 `PictureLayer×6593 OpacityLayer×4395 ClipPathLayer×1098`，rss 1206→1247MB）
- **真实性**：✅ 真 bug（根因 `fushi/lib/src/media/online/installed_online_source_row.dart` 的 `InstalledSourcesGroup`：整组是 `Column` / `FushiReorderableColumn`（`Stack`+`Flex`），被 `fushi/lib/src/media/manga/mihon/mihon_installed_sources_section.dart:612,623` 与 `fushi/lib/src/media/novel/online/lnreader_installed_sources_section.dart:310,323` 包进 `SliverToBoxAdapter`——视口裁不掉屏外行，每一行都实体化、布局、绘制并留在合成树里）
- **[x] ① 已修复** — `InstalledSourcesGroup` 改成 sliver（`SliverMainAxisGroup` = 组标题 + 行列表），不可拖时走 `SliverList.builder`，可拖时走新组件 `FushiSliverReorderableList`（`fushi/lib/src/utils/components/fushi_sliver_reorderable_list.dart`：懒建 + 列表 State 持有拖拽识别器 + 按已布局相邻行的屏幕矩形换位 + 边缘自动滚动，不借 Overlay，祖先缩放下零漂移，同 BUG-778 纪律）；两处调用去掉 `SliverToBoxAdapter`。另：内存采样探针加 `lhot=`（合成树扇出点及其归属），以后同类问题日志里直接点名是哪串子树。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/mihon_import_segments_test.dart`（400 个已装源实建行数 < 60；鼠标拖拽重排写穿排序）、`fushi/test/utils/components/fushi_sliver_reorderable_list_test.dart`（懒建、越过中线换位提交、未越过不提交、触摸快滑交给滚动）、`fushi/test/diagnostics/ui_activity_probe_test.dart`（`lhot=` 点名扇出点与 `Opacity<_HeavyRow×300`）。测试未在本分支运行，统一在合并后验证。
- **备注**：任务派发时推测的「数千个骨架闪光常驻」不成立：日志里的 `_FushiSkeletonShimmerState.didChangeDependencies…×2484` 是 `fcb=`（帧回调**注册次数**，ticker 每帧续排记一次），同一窗口 295 帧 ≈ 平均 8 个 shimmer 在扫（发现页加载中的骨架卡，各自有界 3 轮即停），不是 2484 个实例；空闲时 `frames=0`、`layers=` 里也没有 ShaderMaskLayer。空闲期 rss 仍涨 41MB 的来源本条没有证据定论（合成树静止时 layer 本身不增长），留给 `lhot=` 上线后的下一份报告。

### 根因

`layers=` 的形状是约 1100 组「1 个 ClipPathLayer + 4 个 OpacityLayer + 6 个 PictureLayer」：
`InstalledOnlineSourceRow` 每行是 `FushiGroupedListItem`（M3E 分组形状裁切 → 子树需合成时
推 `ClipPathLayer`），行内 `AnimatedOpacity`（启停淡出，`RenderAnimatedOpacity` 只要不是全透明
就推 `OpacityLayer`）等把一行的绘制切成多张图。Mihon「批量安装」装完一个完整仓库就是一千多个
扩展、一千多组已装源；这些行全在 `SliverToBoxAdapter` 里的一列中，视口只能整块裁切、不能跳过屏外
子树，于是每一帧都布局并绘制全部行，合成树常驻上万个 layer。同类问题此前在扩展目录修过
（BUG-1441，`MihonExtensionsPage` 改 `SliverList`），已装源这一节漏了。
