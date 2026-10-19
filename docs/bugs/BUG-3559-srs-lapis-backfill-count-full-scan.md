## BUG-3559 · 复习：旧 Lapis 补迁角标每次全量物化 Fushi 卡片笔记且逐条重建内置笔记类型，1 万条笔记打开笔记类型页要 60 秒以上
- **报告**：2026-10-19（PR #2336 审查遗留，协调要求根本性修复）
- **真实性**：✅ 真 bug，实测（内存库 1 万条 Fushi 卡片笔记，算一次 `legacyLapisPendingCounts()`）：没有待补迁时 172 条语句、读回 140,037 行、60–70 秒；1000 条待补迁时 58–65 秒。根因：
  - `packages/fushi_engine/lib/srs/srs_legacy_lapis_migration.dart`（修前 :725-726）`previewLapisBackfill` 对全部 Fushi 卡片笔记 `notes(ids)` 全量物化；内置 Lapis 恒在，`owners.isEmpty` 提前返回永远走不到。
  - 同文件（修前 :259-269）`_targetKey` / `srsLapisFieldSlot` 每次调用都 `srsBuiltinNoteTypeForKey` 重建内置定义（约 9 毫秒一条笔记，60 秒里的绝大部分）。
  - 入口：`srs_note_types_page.dart:104`、`srs_deck_list_page.dart:69` 经 `legacyLapisPendingCounts`；`migrateLegacyLapis` / `applyLapisBackfill` 同样受根因 B 拖慢。
- **[x] ① 已修复** — 候选先在 SQL 里按必要条件筛（`_lapisBackfillCandidates`：当前类型是 Fushi 卡片且未删除、旧 Lapis 字段有非空值记录、目标字段一条记录都没有；组合表与笔记 ID 用 JSON 参数传，固定连接顺序），只物化候选、仍走原逐条判定，结果与修前完全一致；内置字段名表按 (profileUid, key) 缓存（`_builtinFieldNames`）；可迁移数改为 SQL `GROUP BY note_type_id` 计数。不改 schema。1 万条：没有待补迁 12 条语句、38 行、36–38 毫秒；1000 条待补迁 30 条语句、160 毫秒。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/srs/srs_legacy_lapis_backfill_scale_test.dart`：规模守卫（40 / 320 条、无关笔记多 8 倍时语句数与读回行数相同）、6 个随机种子与修前实现逐条比较的等价性测试、`FUSHI_SRS_BENCH=1` 才跑的实测用例；变异实测：改回全量物化、去掉「目标字段无记录」、非空判断反过来、目标字段填错、可迁移数计入已删除笔记，五个变异全部变红。
- **备注**：根因 B 的缓存与 SQL 连接顺序只影响墙钟时间，计数守卫抓不到，回归靠实测用例发现（没加按时间判定的测试，避免不稳定）。
