# 统一合集 UI v2：Jellyfin 排版（页头展开按钮 + 概览条 + 合集横排行）实现计划

> **For agentic workers:** 按任务逐条执行，checkbox 跟踪。父计划：`2026-07-11-unified-collections-plan.md`（Phase 1-6 已落地，PR#41）。

**Goal:** 按用户给的两张 mockup 迭代两个库页排版：①页头动作按钮宽屏展开为「图标+文字」；②视频页顶部加「继续观看 hero + 媒体库概览统计」（用户拍板：不做 mockup 的收藏筛选，换成统计）；③**每个合集独占一行**，行内横向滚动显示相邻集、点集直接进对应集（书+视频两页）；④视频卡补「上次观看/已看至」文字外显（书卡已有标签叠加+进度条，不动共享布局）。

**Architecture:** 全部纯 UI/纯函数增量，零 schema 改动。统计与 hero 从已加载的 `VideoBookRow` 全量行 + `VideoWatchStatistics`（title+dateKey+lastModified）内存推导；合集行复用 `groupByCollections` 现有输出，把「合集 group」从网格 cell 改渲染成全宽 sliver 行（散卡仍走网格，交错保序）。

**Tech Stack:** Flutter 3.44 / Riverpod / Drift（只读现有 DAO）/ Slang i18n（走 `tool/i18n_sync.dart`）。

---

## 用户需求 → 阶段映射

| 用户原话 | 阶段 |
|---|---|
| 「把导入视频、媒体库按钮等可展开时展开」 | A |
| 「继续观看，这个筛选就不太行，可以换成统计」 | B（hero 保留，收藏筛选→媒体库概览统计） |
| 「每个合集我想让他独占一行……左右横移来切换集（应该同时显示附近几集）」 | C |
| 「书卡外显、视频外显、标签或许可以抄这个」 | D（增量：视频卡文字进度行；书卡已有标签叠加+进度条） |

## 已核实代码事实（探查报告 2026-07-11）

- 页头按钮：视频页 `home_video_page.dart:1477-1512`（4 × `HibikiIconButton` 纯图标：add / folder_copy / collections_bookmark / bar_chart）；书架 `reader_hibiki_history_page.dart:369-407`（`_headerAction` 同款）。宽窗判定既有先例 `windowSizeClassReal(MediaQuery.sizeOf(context).width, HibikiAppUiScale.of(context))`（hibiki_material_components.dart:1638）。
- App 内**不存在**「继续观看」筛选和收藏筛选——mockup 的「收藏筛选」面板即用户否掉的东西；两页唯一筛选是共享 `HibikiTagFilterBar`。
- `VideoBooks` 列：lastPositionMs / importedAt / completedAt / currentEpisode / coverPath…**无总时长、无 lastWatchedAt**。上次观看时间从 `VideoWatchStatistics(title, dateKey, lastModified)` 推导（title 键控）。
- 视频库主网格 `_buildLocalVideoGridSliver`（:1662）：`SliverGrid` maxCrossAxisExtent 280 / mainAxisExtent 200；合集 group → `SeriesShelfCard` 马赛克折叠卡（:1702-1719）；点开 → `MediaCollectionDetailPage`（有序剧集列表）。
- 书架主网格 `_buildBodyWithSrtBooks`（:808-1030）：`SliverGrid` childAspectRatio `kShelfBookCardAspectRatio`；合集 group → `SeriesShelfCard`（focusId `reader-shelf-collection-<id>`，标签栏「整理」的 down-anchor 指向第一张卡 :969-979）；点开 → `MediaCollectionGridDetailPage`（无序网格）。
- 视频单卡 `_buildCard`（:1751）已有：封面叠标签 chip（≤3+N）、播放列表角标、贴底进度条、标题。书卡（`card_widgets.part.dart` `_bookCardLayout`）已有：标签叠加、类型徽章、封面底进度条。
- `_open(book, {int? playlistCollectionId})`（:710）→ `VideoHibikiPage.neutralized`；传 collectionId 即带剧集面板/上下集/连播。
- 合集「继续看」纯函数已有：`collection_continue.dart` `continueMemberIndex(List<CollectionMemberProgress>)`。
- VideoBooks 无 count 聚合 DAO；库页本就全量拉行（`repo.listForShelf()`），统计条内存算，不加 DAO。

---

### 二轮探查补充（焦点/守卫/尺寸）

- 焦点：`HibikiFocusController.move` 几何打分遍历已注册 target；焦点被遮挡时 `_scheduleReveal → Scrollable.ensureVisible(alignment:0.5)` 自动滚入（含横轴）；controller 无方向 target 时 `scrollByViewportFraction` 按轴匹配滚动（左右键只滚横向 Scrollable）。横向 `ListView` 靠默认 cacheExtent 预建邻卡注册焦点——与现有纵向 SliverGrid 同一行为等级。
- MD3 守卫：新文件走 `tokens.radii/*`+`tokens.surfaces.*`+`tokens.type.*` 且不写 `BorderRadius.circular(`/`fontSize:`/`Card(`/`ListTile(`/`VisualDensity.compact`/裸 `surfaceContainer*` → **零 allowlist 通过**；否则需登记理由。
- 尺寸：书卡槽比 `kShelfBookCardAspectRatio=160/260`、footer 40；书行卡宽 = `readerShelfGridExtentForWidth`（150~210 断点）同源；视频行卡宽 260 / 高 200（对齐网格 mainAxisExtent）。`ListView.builder` 无 initialScrollIndex → `ScrollController(initialScrollOffset: idx*(w+gap))`。
- i18n：Phase A 全部复用现有 tooltip key（video_import_action / media_source_manage_title / collections / video_statistics / reading_statistics 等），零新 key；Phase B/C 需新增（continue watching / overview / 统计三格 / watched-up-to / last-watched / view-all）。`series_item_count`（`$n` items）可复用为行头数量文本。
- 横向卡片行无现成组件（最近先例是 tag_filter_bar 的横向 chip ListView.separated）——C1 新组件是仓库首个，命名 `CollectionShelfRow`。

## Phase A：页头动作按钮宽屏展开（图标+文字）

**Files:**
- Modify: `hibiki/lib/src/utils/components/hibiki_icon_button.dart`（新增 `HibikiHeaderActionButton`）
- Modify: `hibiki/lib/src/pages/implementations/home_video_page.dart:1477-1512`
- Modify: `hibiki/lib/src/pages/implementations/reader_hibiki_history_page.dart:369-419`
- Test: `hibiki/test/widgets/hibiki_header_action_button_test.dart`

- [ ] A1 新组件 `HibikiHeaderActionButton({icon, label, onTap, enabled, focusId})`：`windowSizeClassReal` ≥ medium（≥600 实宽）→ 药丸型 InkWell（Icon + label，`tokens` 配色，StadiumBorder，保持 `HibikiFocusTarget` 注册与 tooltip 语义）；compact → 原样回落 `HibikiIconButton`。
- [ ] A2 视频页 4 个动作 + 书架页 `_headerAction` 改用新组件（书架 `buildBookImportButton` 若为 mediaSource 定制 builder，则给它加 label 参数或包装，保持 `kShelfImportFocusId` 不变——焦点 anchor 依赖它）。
- [ ] A3 widget 测试：宽窗渲染 label 文本、窄窗只有图标、onTap 触发、focus 可达。
- [ ] A4 `flutter analyze` + 相关测试 → commit `feat(ui): 页头动作按钮宽屏展开为图标+文字`。

## Phase B：视频页顶部「继续观看 hero + 媒体库概览」

**Files:**
- Create: `hibiki/lib/src/media/video/video_library_overview.dart`（纯函数）
- Modify: `hibiki/lib/src/pages/implementations/home_video_page.dart`（`_buildVideoLibraryBody` 顶部插 `SliverToBoxAdapter`）
- Test: `hibiki/test/media/video_library_overview_test.dart`

- [ ] B1 纯函数 `computeVideoLibraryOverview({rows, watchStats, now})` → `{total, unfinished, recentImportCount(7天), lastActivityAt, hero?}`；hero = `lastPositionMs>0 && completedAt==null` 中「watch-stats lastModified 最新（按 title 匹配）→ 回退 importedAt 最新」；全无痕迹 → hero=null。单测覆盖：空库/全看完/title 无统计回退/7 天窗口边界。
- [ ] B2 UI `_buildOverviewSection`：hero 卡（左封面缩略 + 标题 + 「已看至 mm:ss」+ 上次观看日期 + 继续观看按钮 → `_open(hero, playlistCollectionId: 其 primary 合集)`）+ 概览统计（总数/未完成/最近导入 + 最近活动时间）。宽窗并排、窄窗纵向堆叠；空库整段隐藏。**不显示百分比**（无总时长，不造假）。
- [ ] B3 i18n：`tool/i18n_sync.dart --add`（continue_watching / library_overview / stat_total_videos / stat_unfinished / stat_recent_imports / watched_up_to / last_watched_at 等）→ `dart run slang` + `dart format` 生成文件。
- [ ] B4 analyze + 测试 → commit `feat(video): 库页顶部继续观看 hero + 媒体库概览统计`。

## Phase C：合集独占一行 + 行内横向切集（两页）

**Files:**
- Create: `hibiki/lib/src/media/collections/collection_shelf_row.dart`
- Modify: `hibiki/lib/src/pages/implementations/home_video_page.dart`（`_buildLocalVideoGridSliver` → 交错 slivers）
- Modify: `hibiki/lib/src/pages/implementations/reader_hibiki_history_page.dart`（`_buildBodyWithSrtBooks` 主网格同改）
- Test: `hibiki/test/media/collection_shelf_row_test.dart` + 守卫更新

- [ ] C1 通用行组件 `CollectionShelfRow`：头（合集名 + 「N 集/本」+ 查看全部 chevron，携带 focusId `reader-shelf-collection-<id>`/视频等价——保持既有 focus anchor 语义）+ 固定高横向 `ListView.builder`（成员卡 builder 回调、固定卡宽、`initialScrollIndex` 定位）。
- [ ] C2 sliver 交错：`groupByCollections` 输出按序扫描——连续散 group 段落 → 一个 `SliverGrid`；合集 group → 一个 `SliverToBoxAdapter(CollectionShelfRow)`。**保序**（组间序不变），零合集时退化为与现状 100% 相同的单网格。
- [ ] C3 视频页接线：成员卡 = `_buildCard(ep, playlistCollectionId: collection.id)`（`_buildCard` 加可选参数透传给 `_open`——点某集直接从该集进播放器带剧集面板 =「左右横移来切换集」）；`initialScrollIndex` = `continueMemberIndex`。行高对齐网格 cell（200 + 标题）。
- [ ] C4 书架页接线：成员卡 = `_buildSrtCard` / `buildMediaItem`（onTap 已开书）套固定宽；`initialScrollIndex` 书侧 v1 = 0（书行无统一进度 trace，不硬造）；行卡宽 = 网格 extent 同源。标签栏 down-anchor `_shelfGroupFocusId` 改指向行头 focusId。
- [ ] C5 `SeriesShelfCard` 在两页主网格不再被引用（合集详情页/重排页如仍用则保留组件本身，不删文件）。架构守卫 `unified_collections_architecture_guard_test.dart` 更新：主网格必须含 `CollectionShelfRow`。
- [ ] C6 analyze + 两页相关测试 → commit `feat(collections): 合集独占一行横向切集（Jellyfin 行式布局）`。

## Phase D：视频卡文字外显

- [ ] D1 `_buildCard` 标题下加一行小字（onSurfaceVariant）：`已看至 mm:ss`（lastPositionMs>0 时）或 `已看完`（completedAt 非空）+ 上次观看日期（watch-stats 有该 title 时）。无任何痕迹 → 不渲染该行（网格 mainAxisExtent 相应 +16~20）。书卡不动（已有标签+进度条，改共享布局会牵连 golden）。
- [ ] D2 analyze + 测试 → commit `feat(video): 视频卡外显观看进度与上次观看`。

## Phase E：砍掉重做「整理排序」页（用户 2026-07-11 拍板）

用户：「这个编辑排序很烂，你顺便砍掉重做」。**根因**：旧 `ShelfReorderPage` 拖拽合并仍写旧 Series 表（`onMerge: _mergeShelfEntries` → series），而主网格自 Phase 4 只按 MediaCollections 折叠——整理页合并出的组主网格不显示，页面事实性坏。这正是父计划 §8 缓过的死角，现在用户明确要求重做。

**Files:**
- Rewrite: `hibiki/lib/src/pages/implementations/shelf_reorder_page.dart`（新模型，复用 `HibikiReorderableColumn`/`hibiki_reorderable_grid` 共享组件，不重写拖拽原语）
- Modify: `reader_hibiki_history_page.dart` / `home_video_page.dart`（`_openShelfSort`/`_openVideoSort` 接线新页 + 合并回调换合集 API）
- Delete-after: `SeriesReorderFrame`（series_shelf_card.dart 内）、`groupAndSortShelfEntries` 消费点、`_mergeShelfEntries` series 写路径
- Test: 重排/合并写穿断言（新建/成员/排序真写 MediaCollections 两表）+ 架构守卫「整理页不得再写 setSeriesForEntry」

- [ ] E1 数据模型：整理页分组读 `groupByCollections` 同源输出（与主网格一个真相源）；排序单位 = group（合集=一个可拖单元，散卡=一个单元）；组内成员单独重排。
- [ ] E2 写路径：单元重排 → `ShelfEntries.sortOrder`（散卡）+ `MediaCollections.sortOrder`（合集）；拖卡入合集/卡上叠卡 → `createMediaCollection`+`addToCollection`；移出 → `removeFromCollection`。**零 series 写入**。
- [ ] E3 UI：对齐 Phase C 行隐喻——合集渲染为可整体拖动的行单元（头+成员缩略），展开后组内重排；散卡网格拖拽复用现有 reorderable grid。
- [ ] E4 删死代码：`SeriesReorderFrame` + series 合并回调 + `groupAndSortShelfEntries`（若无其它消费者）+ 守卫锁死 `shelf_reorder_page.dart` 不含 `setSeriesForEntry`/`seriesId`。
- [ ] E5 analyze + 写穿测试 → commit `feat(shelf): 整理排序页按合集模型重做（砍掉 series 写路径）`。
- 真机边界：拖拽手势成功率/手感需真机复测（铁律），离屏只能锁写穿正确性。

## 收尾

- [ ] MD3 守卫 allowlist 按需登记新文件（原因注明「媒体封面内容卡，同 series_shelf_card 类」）。
- [ ] 全量 `flutter analyze`（lib+test，warning=fatal）+ 全量 `flutter test`。
- [ ] Workflow 对抗审查（正确性/回归/焦点导航三镜头）→ 修复 → 复审。
- [ ] push PR#41；回报：视觉/焦点遍历/真机拖拽仍需真机复测（铁律）。

## 风险与破坏面

- **保序**：C2 的交错 sliver 必须保持 `groupByCollections` 组间序；零合集库退化路径 = 现状单网格（守卫锁）。
- **焦点/手柄**：横向行内左右键遍历 + 行间上下键切换依赖既有 focus 几何系统（等待第二份探查确认 `Scrollable.ensureVisible`-on-focus 既有行为）；书架标签栏 down-anchor 必须仍可达。真机验证项。
- **选择模式/拖标签**：行内成员卡复用原 builder，批量选择、拖放打标签行为保持；批量操作在行内卡上同样生效。
- **窄屏**：行横滚在手机是自然手势；hero/统计条窄屏纵向堆叠。
- **不造假数据**：无总时长 → 不显示百分比；书行无统一 trace → 不做 initialScrollIndex。

## 执行状态

（随实现更新）
