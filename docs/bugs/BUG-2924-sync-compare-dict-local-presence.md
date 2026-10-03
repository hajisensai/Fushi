## BUG-2924 · 同步对比词典行不显示本地是否存在
- **报告**：2026-10-04（用户：GitHub issue #1473，yimkdesu）
- **真实性**：✅ 真 bug。`_fetchDictEntries` 早已按名字对齐出 `SyncDictEntry.hasLocal`，但词典行的标签 `fushi/lib/src/sync/sync_compare_dialog.dart:1729`（原 `d.hasRemote ? t.sync_compare_remote : t.sync_compare_local`）是二选一：只要云端有就只写「远端」，两端都有的词典与仅云端的词典显示完全一样，用户看不出本地装没装。
- **[x] ① 已修复** — 标签改由 `SyncDictEntry.presenceLabel`（`sync_compare_dialog.dart:162`）按实际存在的每一端拼出「本地 · 远端」/「远端」/「本地」，复用既有 i18n key。提交见 PR。
- **[x] ② 已加自动化测试** — `fushi/test/sync/sync_compare_delete_test.dart` group `dictionary row presence label (#1473)`：两端都有 / 仅远端 / 仅本地三条，精确匹配标签文本；变异实测还原旧三元后「两端都有」用例变红。
- **备注**：标题「Local vs remote」本身含 Local，测试必须用 `find.text` 精确匹配而非 `textContaining`。
