## BUG-3098 · 重复导入同一有声书包撞 SrtBooks UNIQUE uid
- **报告**：2026-10-09（实现「从互联对端重新下载有声书」时沿真实代码路径发现；用户需求：书架重新拉取有声书 / 字幕）
- **真实性**：✅ 真 bug。`packages/fushi_engine/lib/sync/sync_asset_package_service.dart` 的 `importAudioDatabasePackage`（srt-backed 与 standalone 两个分支）用 `SrtBooksCompanion.insert(uid: …)` 不带 `id` 调 `upsertSrtBook`；`upsertSrtBook`（`packages/fushi_core/lib/src/database/database_library.part.dart:1485`）是 `insertOnConflictUpdate`，drift 的冲突目标默认是主键 `id`，于是本机已有同 uid 行时撞的是 UNIQUE(uid) → `SqliteException(2067)`，整个写库事务回滚。凡是「同一本有声书第二次导入」都中招：书架补拉坏包（BUG-2551 场景）、新加的「重新下载有声书」。`SrtBookRepository.save` 早就为同一个原因带了 `id`，包导入这条路漏了；`audio_package_srt_tags_test.dart` 的注释也写着「不依赖包能否被重复导入」。
- **[x] ① 已修复** — 导入前按包里的 uid、再按 bookKey 找本机已有的 SrtBooks 行（`_existingSrtBookFor`），带上它的 `id` 原位更新；按 bookKey 命中时沿用本机 uid（书架条目 / 标签 / 合集挂在本机 uid 上，换成 host uid 会多出一本同 bookKey 的 SRT 书）。提交见 PR `pr/interconnect-refetch-assets`。
- **[x] ② 已加自动化测试** — `fushi/test/sync/interconnect_audiobook_refetch_test.dart`「BUG-3098：重新下载整本有声书（fresh）…」：真 host + 真 client 端到端二次下载同一本有声书。去掉修复后该测试红在 `UNIQUE constraint failed: srt_books.uid`，恢复后绿。
- **备注**：同一测试还覆盖 host 导出缓存（15 分钟 TTL）——「重新下载」带 `?fresh=1` 让 host 作废旧导出，否则 host 刚改完字幕拿回来的仍是旧包。
