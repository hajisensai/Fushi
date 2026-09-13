## BUG-2475 · 备份取消勾选「统计」仍外泄 study_segments
- **报告**：2026-09-12（用户要求「所有数据类别都可选导出/导入」时审计发现）
- **真实性**：✅ 真 bug。`fushi/lib/src/sync/backup_service.dart` 的 `_statisticsTables` 在 v92 加了唯一事实表 `study_segments` / `study_segment_tombstones` 之后没有跟进，导出时取消勾选「统计」只 DELETE 旧的 reading/video/mining 统计表，学习时长事实原样随包走；覆盖导入未勾「统计」同样裁不掉。
- **[x] ① 已修复** — `_statisticsTables` 补上两张表（`backup_service.dart:618-629`），`statsCount` 改为含 `study_segments`（`_countStatisticsRows`）；提交 `07ab311561`。
- **[x] ② 已加自动化测试** — `fushi/test/sync/backup_games_category_test.dart`「统计类别裁 study_segments」用例。
- **备注**：与 BUG-2476 同一提交（备份 games 类别 PR）。
