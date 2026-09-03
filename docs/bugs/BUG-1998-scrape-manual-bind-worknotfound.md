## BUG-1998 · 手动指定作品对已不在计划的作品裸抛 VideoSourceScrapeWorkNotFound 进 UI
- **报告**：2026-09-01（用户：手动指定「哆啦A梦：大雄的秘密道具博物馆」→ 对话框显示 `VideoSourceScrapeWorkNotFound(...)` 裸异常，无法搜索也无法绑定）
- **真实性**：✅ 真 bug。两层根因：
  - `fushi/lib/src/media/video/metadata/video_source_scrape_coordinator.dart:118`（修前）：`searchManualCandidates` 在联网搜索**之前**按标题字符串回查当前来源计划（`_plannedWork`），查不到直接抛——而它要计划作品只为推导 mediaKind 一个参数。历史 run 记的是刮削当时的作品标题，文件改名/移动/删除后标题漂移，计划回查必然失败。
  - `fushi/lib/src/media/video/metadata/video_source_scrape_run_detail_dialog.dart:284`（修前）：搜索/绑定失败路径 `_error = error.toString()`，异常原文进 UI。
- **[x] ① 已修复** — `194637edab`：搜索不再前置计划回查（作品缺席时按 tv+movie 双形态各搜一次、按 `(mediaKind, externalId)` 去重）；`VideoSourceScrapeWorkNotFound` 在 run 详情与手动搜索对话框统一映射为本地化文案 `video_source_scrape_work_missing`；后台任务面板新增按 stableKey 从当前计划派生的「待确认作品」队列，绑定入口结构上不可能再指向已消失的作品。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/metadata/video_source_scrape_coordinator_test.dart`（「手动搜索：作品不在当前计划时不抛异常，双形态搜索按身份合并」）；队列派生见 `fushi/test/media/video/metadata/video_library_scrape_sweep_test.dart`。
- **备注**：`rescrapeWorkWithLookup` 对不存在的作品仍按契约抛错（不能把资料绑到不存在的文件上），但 UI 侧全部本地化。
