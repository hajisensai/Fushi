## BUG-2220 · 统计墓碑用本机墙钟直比对端 updatedAt 且本机碑只进不出
- **报告**：2026-09-06（用户：审查「小说统计是否会出现异常」）
- **真实性**：✅ 真 bug。根因 `packages/fushi_core/lib/src/database/database_content_misc.part.dart:218-224`（`deleteStudySegmentsForMedia` 用本机 `DateTime.now()` 立碑且 `insertOnConflictUpdate` 无 `where` 守卫，再删一次可把已收到的更新碑戳倒退）+ `aggregate_merge_service.dart:137/141`（碑 `deletedAt` 与对端墙钟 `updatedAt` 直比大小：对端超前 → 碑当轮出局、段全存活、下轮回灌，且本机不会再立第二次碑）+ 本机墓碑只进不出（`aggregate_sync_service.dart:970-976` 只写快照里的碑，在线路径没有任何代码删本机碑）→ 两端对同一媒体的历史永久分歧。
- **[x] ① 已修复** — 与 BUG-2214 同一改动：墓碑永不退场（live = 全部合并后的碑，本机碑与快照碑同集，不再「只进不出」）；压制判据改为段的 `startAt`（删除时刻附近那一段的归属才受 skew 影响，不会整块翻转）；`upsertStudySegmentTombstone` 收敛为唯一写碑入口，只在 `deletedAt` 更大时覆盖（碑戳只增不减），本机删除与同步 / 备份落地都经它。 提交：`bef9747e30`。
- **[x] ② 已加自动化测试** — `fushi/test/sync/aggregate_study_segments_sync_test.dart`「两端墙钟 skew：对端时钟超前的段 updatedAt 再大也压不掉碑」+ `fushi/test/database/study_segments_test.dart`「applyStudySegmentTombstone 按 startAt 删、碑戳只增不减」。
- **备注**：
