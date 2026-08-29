## BUG-1947 · 视频统计同步按 title 塌缩：分集裸集号跨作品相加、per-uid 行被删成无身份行
- **报告**：2026-08-29（用户：「统计经常有重复统计、字数超高、一个视频几十分钟能变成几个小时」；本条是沿同步链验出的结构性根因之一）
- **真实性**：✅ 真 bug。根因（修前行号）：
  - `fushi/lib/src/sync/aggregate_sync_service.dart:685-712` `_foldVideoStatRows`：视频统计的 wire 键是 `(title, dateKey)`、不含 bookUid，物化时把同 title 的全部 per-uid 行**求和**上行，注释自己承认「重叠时汇总偏高并经 MAX 固化」；
  - `packages/fushi_core/lib/src/database/database_statistics.part.dart:624-680` `setVideoWatchStatistic`：对端 apply 时按 (title, dateKey) 取 max 后**删掉该 title 全部 per-uid 行、写回一条 NULL-uid 行**；
  - 分集视频的 `VideoBooks.title` 是裸集号 `S01E01`（BUG-1350 已实锤），10 部番的第一集在 wire 上是同一个键——跨作品相加，再跨设备 MAX 固化，读取端 per-uid 身份分组也被塌缩行抹掉。只要开过一次互联 / 云同步就中招，形状与「一个视频几十分钟变几小时」吻合。
- **[x] ① 已修复** — 结构性：v90 起观看时长 / 字幕字数只写 `study_segments`（`media_key = bookUid`，按 uid 幂等 upsert，见 `docs/plans/2026-08-29-statistics-fact-table-refactor.md`），legacy `video_watch_statistics` 冻结、本地永不再写——本机事实不再经过 title 键控的 wire 与 `setVideoWatchStatistic` 塌缩。读取侧 `loadStatFacts` 把段与 legacy 行并集，段按 bookUid 分组。wire v2（按 uid 并集、删 MAX-union / 塌缩 / deficit-lift）在 PR B 落地，本条 ① 只覆盖「本地不再被塌缩」。提交：本分支。
- **[x] ② 已加自动化测试** — `fushi/test/database/study_segments_test.dart`（按 uid 幂等、按身份删除）+ `fushi/test/pages/video_stat_aggregates_test.dart`（事实面按 mediaKey 分组，同名不同 uid 各自成 tile）+ `fushi/test/tools/statistics_write_convergence_guard_test.dart`（① 本地写入面零直写 legacy 表；③ 页面只经 loadStatFacts）。
- **备注**：legacy 表里已被塌缩的历史行不回溯修正（无法判定原始归属）。PR B 之前，旧端上传的 legacy 家族仍会按 title MAX 进本机 legacy 表——那是旧数据的旧口径，不影响 v90 后的段。
