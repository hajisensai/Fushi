## BUG-1720 · 视频刮削「待确认 N」没有任何确认入口
- **报告**：2026-08-18（用户：截图指向视频导入页来源行「上次刮削（已完成）：成功 22，待确认 2，失败 4」）
- **真实性**：✅ 真 bug。根因是「待确认」被拆成两半——**计数持久化、对象即时丢弃**：
  - `fushi/lib/src/media/video/metadata/video_source_scrape_coordinator.dart:495-501`：`resolution.status == ambiguous` 且 `onConfirmation == null` 时直接 `return _ResolvedWork(pending: true)`，刚算出来的候选列表 `options` 就地丢掉。
  - `fushi/lib/src/pages/implementations/home_page.dart:2031`：扫描后自动刮削走 `scrapeSource(source)` 的默认 `interactive: false`，即 `onConfirmation == null`——用户那条「已完成，待确认 2」正是这条路径产生的。
  - `fushi/lib/src/media/video/metadata/video_source_scrape_coordinator.dart:243-252`：只把 `pending++` 累进计数，写进 `video_source_scrape_runs.pendingConfirmations`（`:1352`）。
  - `fushi/lib/src/media/video/metadata/video_source_scrape_task.dart:210-211`：真正的待确认对象是一个只活在交互式 run 期间的内存 `Completer`，run 一结束就没了。
  - `fushi/lib/src/pages/implementations/media_sources_view.dart:535-549`：摘要行把这个数字渲染成**纯 Text**，没有任何 affordance。

  合起来：run 结束后「待确认 2」是一个死数字，既没有可确认的对象，也没有任何入口能重新产出它。
- **[x] ① 已修复** — 不去持久化候选（候选来自网络、会过期，持久化即缓存一致性地狱），而是让这个数字**可点、可重新推导**：
  - 摘要行改成可点（`media_sources_view.dart` 的 `_buildStatusLine` + `_openScrapeRunDetail`），打开新的 `showVideoSourceScrapeRunDetailDialog`（`fushi/lib/src/media/video/metadata/video_source_scrape_run_detail_dialog.dart`）。
  - 详情从 run 的 `summaryJson` 读回逐条作品级事实（待确认走 warnings、失败走 errors），编解码收在 `video_source_scrape_task.dart` 的 `encodeSourceScrapeReport` / `decodeSourceScrapeReport`（协调器 `_reportJson` 改为复用，wire 形状只有一份）。
  - 每条提供「手动指定作品」：搜索走 `VideoSourceScrapeManualBinding.searchManualCandidates`，选中后 `rescrapeWorkWithLookup` 把 lookup 当已确认身份塞回 `scrapeSource(confirmedLookups:)`，与批次内确认、与下载导入后的精确刮削**共用同一条 `_store.apply` 落库路径**，不新开第二套绑定保存。
  - 候选行抽成共享 `VideoSourceScrapeCandidateTile`，批次内确认与手动指定同一份呈现与点击语义。
- **[x] ② 已加自动化测试** — `fushi/test/pages/video_source_scrape_ui_test.dart`：
  - `import row summary opens the run detail with its issues (BUG-1720)`
  - `manual binding searches and rebinds through the shared path`
  - `run summary json round-trips the per-work issues`
  变异实测：把 `_buildStatusLine` 里摘要行的 `onTap` 改成 `null` → 两条 widget 测试红；还原后 sha256 与变异前一致。
- **备注**：同一批用户反馈的另一半是历史任务无重刮/手动指定入口，见 BUG-1721（同一条修复路径）。
