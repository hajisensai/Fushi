## BUG-2476 · 备份导入对话框永不显示「进度」「统计」开关
- **报告**：2026-09-12（用户要求「所有数据类别都可选导出/导入」时审计发现）
- **真实性**：✅ 真 bug。`importSelectableCategories`（`fushi/lib/src/sync/sync_settings_schema/backup.part.dart`）含 progress / statistics，但对话框按 `summary.has(c)` 过滤显示，而 `summarizeBackupEntries`（`fushi/lib/src/sync/backup_service/restore.part.dart`）的 `present` 集合只由 6 个文件树类别填充，progress / statistics 永远不在 present 里 → 开关永不出现 → 被当作「未提供开关 = 总是导入」，用户无法在导入时跳过进度/统计。
- **[x] ① 已修复** — `summarizeBackupEntries` 新增 `dbProgressCount` / `dbStatisticsCount`（老包 meta 缺计数时 `_peekContentRowCounts` 窥探 DB），present 补 progress / statistics（顺带 games）；`BackupMeta` 新增 `progressCount`；`summarizeLiveContent` 同步（`restore.part.dart:77-146`）；提交 `07ab311561`。
- **[x] ② 已加自动化测试** — `fushi/test/sync/backup_games_category_test.dart`「导入摘要 meta / 窥探 / 纯函数」用例断言 present 含 progress / statistics。
- **备注**：与 BUG-2475 同一提交。
