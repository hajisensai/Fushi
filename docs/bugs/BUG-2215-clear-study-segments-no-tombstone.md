## BUG-2215 · 清空全部统计不立墓碑，多端同步整批复活
- **报告**：2026-09-06（用户：审查「小说统计是否会出现异常」）
- **真实性**：✅ 真 bug。根因 `packages/fushi_core/lib/src/database/database_content_misc.part.dart:230-231`：`clearStudySegments` 只删行、有意不立碑（注释称逐媒体立碑会「永久毒化身份空间」——那是旧墓碑语义下的顾虑）。多端 / 互联场景「清空全部阅读 / 视频统计」后，`aggregate_sync_service.dart:411-414` 本地空集 ∪ 对端全集 → `:978` 落地，一次同步全部复活，`updatedAt` 原样、无碑可拦。
- **[x] ① 已修复** — 新墓碑语义（BUG-2214：只压制 `startAt < deletedAt` 的段）下立碑不再毒化身份：`clearStudySegments` 改为同一事务里 `SELECT DISTINCT media_key` 逐身份 `upsertStudySegmentTombstone(deletedAt = now)` 再删行；`clearAllReadingStatistics` / `clearAllVideoStatistics` 的文档改准确（legacy 家族仍不立 title 碑）。 提交：`bef9747e30`。
- **[x] ② 已加自动化测试** — `fushi/test/database/study_segments_test.dart`「clearStudySegments 只清该种类，并对该种类每个身份立碑」+ `fushi/test/sync/aggregate_study_segments_sync_test.dart`「清空全部统计后同步合并不复活」。
- **备注**：
