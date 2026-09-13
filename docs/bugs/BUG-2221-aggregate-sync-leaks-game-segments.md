## BUG-2221 · 聚合同步/备份不按 mediaKind 过滤，游戏段跨端外流
- **报告**：2026-09-06（用户：审查「小说统计是否会出现异常」）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/sync/aggregate_sync_service.dart:833`（`getStudySegments()` 不按 `mediaKind` 过滤，galgame hook 的 chars-only game 段随聚合快照上行）+ `backup_merge_engine.dart:190`（备份合并全部 kind，而 `:191-196` 明写 galgame_sessions / galgames 刻意不合并）。对端游戏 tab 出现有字数、无时长、`galgames` 查无此行的孤儿条目，与「游戏数据不跨端」冲突。
- **[x] ① 已修复** — 新增 `AggregateMergeService.isStudyKindSyncable`（`mediaKind != kActivityMediaGame`），聚合导出、并集仲裁、落地（旧端直落的游戏段也丢）、备份 ATTACH 四处同一判据过滤段与碑。 提交：`bef9747e30`。
- **[x] ② 已加自动化测试** — `fushi/test/sync/aggregate_study_segments_sync_test.dart`「游戏段 / 碑不出本机、旧端直落的游戏段也不落地」+ 仲裁纯函数用例 + 备份合并用例。
- **备注**：
