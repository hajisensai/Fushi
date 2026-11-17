## BUG-4775 · 合并与快照恢复的有声书进度不受墓碑与排除过滤
- **报告**：2026-11-17（用户：维护者，PR #3518 合入后只读核实的遗留缺陷）
- **真实性**：✅ 真 bug。origin/develop `fushi/lib/src/sync/backup_merge_engine.dart:2195-2202` 的 `_mergeAudiobookPositionPrefs` 只按 `key LIKE 'audiobook_pos_%' AND NOT EXISTS` 插入，没有走书库行用的 `_blockedBookKeysSubquery`（删除墓碑 + `excludedBookKeys`）：合并导入时被删除的书、从覆盖前快照恢复时因书文件不在盘上而跳过的书，其 `audiobook_pos_<bookKey>` / `audiobook_pos_at_<bookKey>` / 字幕书 `audiobook_pos_<srt uid>` 照样落库，留下孤儿进度，按同一 key 重新导入时还会捡回删除前的旧进度。
- **[x] ① 已修复** — `_mergeAudiobookPositionPrefs`（`backup_merge_engine.dart:2199`）加 `NOT IN _blockedBookKeysSubquery`；身份取法（`backup_merge_engine.dart:2213` 起）：剥掉 `audiobook_pos_at_` / `audiobook_pos_` 前缀，若是源库 `srt_books.uid` 则换成该行 `book_key`，否则即 bookKey。提交 `41536b2d5e`。
- **[x] ② 已加自动化测试** — `fushi/test/sync/backup_merge_import_test.dart`「merge does NOT bring back a deleted book's audiobook positions…」（墓碑书的三种键都不落、新书的两种键照常落）；`fushi/test/sync/overwrite_snapshot_recovery_test.dart` 首条测试补断言（书文件缺失被跳过的 C 的 `audiobook_pos_C` / `_at_C` 不落、A 的进度补回）。去掉过滤条件时两处都变红，已实测。
- **备注**：
