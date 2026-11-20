## BUG-5011 · 同步删除书时墓碑写入失败被吞且无日志
- **报告**：2026-11-20（路线图 #3722 c37 novel-17a）
- **真实性**：✅ 真 bug。
  - 根因：`fushi/lib/src/media/sources/reader_fushi_source.dart:1165` 「同步删除」写 `sync_deletion_tombstones` 失败时 `catch (_)` 直接吞掉，无任何日志；用户以为别的设备会跟着删，实际不会，也无从排查。
- **[x] ① 已修复** — catch 里补 `ErrorLogService.instance.log('ReaderFushiSource.deleteBook.syncTombstone', e, stack)`，删除结果照旧不翻转（行已删）。提交见本文件 Git 历史。
- **[x] ② 已增加自动化测试** — `fushi/test/media/sources/reader_fushi_delete_cleanup_test.dart`「BUG-5011」组：Drift 拦截器让墓碑表插入抛错，断言书已删、结果为成功、错误日志里有该来源的记录。
- **备注**：
