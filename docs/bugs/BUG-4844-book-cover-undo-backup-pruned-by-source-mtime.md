## BUG-4844 · book-cover-undo-backup-pruned-by-source-mtime
- **报告**：2026-11-18（用户：实现视频刮削认领撤销时沿同一条撤销备份路径发现）
- **真实性**：✅ 真 bug。书封面撤销备份在 `fushi/lib/src/media/metadata/book_metadata_scrape_facade.dart:454` 用 `File.copy` 建立，复制沿用源文件的修改时间；`_pruneBackups`（同文件 `:461`）按 `lastModified()` 是否早于「现在 − 30 天」删备份。一张 30 天前就在用的封面，备份的修改时间也早于 30 天，下一次任何一本书留备份时就被清掉，撤销报「封面备份已过期」。
- **[x] ① 已修复** — 备份复制完立刻把修改时间设成建立时刻，保留期从备份建立起算。
- **[x] ② 已加自动化测试** — `fushi/test/media/metadata/book_metadata_scrape_facade_test.dart`「旧封面（修改时间早于保留期）的备份按建立时刻算保留期，下次清理不删」：把现用封面的修改时间拨到 40 天前，留备份后再触发一次清理，备份仍在且撤销成功。
- **备注**：AI 库管家会批量写回书封面，这条不修的话整轮撤销对老封面不可靠。
