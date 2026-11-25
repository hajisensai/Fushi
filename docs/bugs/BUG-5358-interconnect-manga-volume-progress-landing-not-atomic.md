## BUG-5358 · 单卷互联漫画同步落地书级 / 章级分两次写，夹着翻页时章级退回 host 旧页
- **报告**：2026-11-24（外部审查报告 HBK-AUDIT-001 P1，针对 #4297 互联漫画进度）
- **真实性**：✅ 真 bug。`fushi/lib/src/sync/interconnect_book_progress_sync.dart` `_upsertLocalIfUnchanged`（develop 上约 608-625 行）先用 `upsertReaderPositionIfUnchanged` 在它自己的事务里比较后写书级，事务提交后再调 `_landInterconnectVolumeChapter` 无前置条件地 `saveMangaChapterState` 写章级。阅读器 `fushi/lib/src/media/manga/reader/manga_fushi_page.dart` `_persistPosition`（约 6723 行起）也分两次写（书级 → 已读完 → 章级），不拿书锁。顺序「同步书级落地 → 阅读器翻页写两表 → 同步章级落地」后书级是新页、章级是 host 旧页；书架开单卷只认章级，新页丢失。章级写抛错时书级已提交、基线未记，下一轮两端位置相同只对齐戳、不再落章级，永久不一致。
- **[x] ① 已修复** — 同步侧 `_upsertLocalIfUnchanged` 把书级比较后写入与章级落地放进同一个 `_db.transaction`（drift 把事务外语句排到事务之后）：并发写者只能整体落在前（书级戳已变 → 前置条件不成立，两表都不动）或后（整体覆盖）；章级写失败两表一起回滚。阅读器 `_persistPosition` 改为同一原语：一个 `db.transaction` 里先书级后章级，「已读完」与 Kavita / tracking 上报移到事务之后。条件写已覆盖并发，不另加书锁。
- **[x] ② 已加自动化测试** — `fushi/test/sync/interconnect_manga_progress_key_test.dart`：真 `FushiSyncServer` host + 钩子 DB，在同步写章级那一刻从根 zone 起阅读器式写入（一个事务写两表到第 60 页），断言两表都是 60（修复前章级 43）；注入章级写失败，断言书级 / 章级 / 基线都没留下，下一轮照常拉到（修复前书级残留 43）。
- **备注**：真机未复测（纯 DB 并发顺序，测试已钉住确定顺序）。
