## BUG-582 · 互联有声书显示成普通书且音频不同步
- **报告**：2026-07-07（用户：明明是有声书，但 hibiki 客户端显示普通书，下载后同步没有把有声书音频同步过来）
- **真实性**：✅ 真 bug。两症状同一根因——host 广播的 `hasAudiobook` 徽章/清单判据要求 audiobooks + srt_books 两表齐备（`_srtBackedAudiobookKeys`，`hibiki/lib/src/sync/app_model_library_host_service.dart:482-504`），而 `audiobook_import_dialog`（给已有 EPUB 书加/换音频）在 `saveAudiobook` 后漏写配对 `srt_books` 行（`hibiki/lib/src/media/audiobook/audiobook_import_dialog.dart:763`）。TODO-894 已修另两条导入路径（`book_import_dialog` / `audiobook_alignment_service`）并加 v29 一次性 backfill，但漏了这条对话框；v29 之后（DB 已 ≥29）经它新导入的有声书重新变回未配对，不再被自愈。
  - 后果①「显示成普通书」：host `listBooks()` 的 `hasAudiobook=false`（`app_model_library_host_service.dart:258`）→ 对端下载走 `_downloadRemoteBook`，`_downloadRemoteAudiobook` 在 `remote.part.dart:466 if (!book.hasAudiobook) return;` 早退，本地不插 Audiobooks 行 → 书架角标（来自 Audiobooks 表，`reader_hibiki_history_page.dart:124-144`）不亮 = 普通书。
  - 后果②「音频不同步」：同一早退跳过整段音频/cue 导入；sweep 侧 `_syncAudiobooksLive` 的 `toPull` 来自 host `listAudiobooks()`（`app_model_library_host_service.dart:495-504`，缺 SrtBook 直接 `continue`）→ 该书永不进同步清单；即便强拉 `exportAudiobook` 也在 `:519-521` 抛 StateError→404。
- **[x] ① 已修复** — 根因数据修复（非消费端补丁）：
  1. `hibiki/lib/src/media/audiobook/audiobook_import_dialog.dart`：`saveAudiobook` 之后，对 EPUB-backed（`getEpubBook(widget.bookKey)!=null`，等价 v29 backfill 的 audiobooks JOIN epub_books）且非 `audioOnly` 的有声书，调用与另三处共用的稳定派生 helper `writeEpubBackedSrtBook`（uid=`srtbook_epub_<bookKey>`，幂等）补写配对 srt_books 行。standalone / audioOnly 天然豁免。
  2. `packages/hibiki_audio/lib/src/audiobook/audiobook_repository.dart`：新增 `HibikiDatabase get database` 供对话框在同一连接上构造 `SrtBookRepository`。
  3. `packages/hibiki_core/lib/src/database/database.dart`：schemaVersion 36→37，`onUpgrade` 加 `from<37` 块重跑幂等的 `backfillMissingAudiobookSrtBooksV29()`，自愈 v29→v36 之间经该对话框导入而残留的历史未配对有声书（NOT IN + INSERT OR IGNORE，重复运行 no-op）。
  - 提交：见本轮 commit（message 含 TODO-1288）。
- **[x] ② 已加自动化测试** —
  - `hibiki/test/database/migration_test.dart`：新增 `_openV36DbWithUnpairedAudiobook` + `real v36->v37 self-heals ...` 用例，断言 v37 自愈把未配对 EPUB-backed 有声书治好、standalone 原封不动、仅两行。并把全文件硬编码 schema 断言 36→37 同步。
  - `hibiki/test/media/audiobook/audiobook_import_dialog_srtbook_pairing_guard_test.dart`：源码守卫，锁住对话框导入路径在 `saveAudiobook` 之后确实调用 `writeEpubBackedSrtBook`（判据 epub_books 存在 + 非 audioOnly）。
  - 配对 helper 行为已由既有 `book_import_srtbook_pairing_test.dart`（TODO-894）覆盖。
- **备注**：跨设备真机验收（同步后有声书显示为有声书 + 音频拉过来）见 TODO-1288 报告口径。env-flaky `test/tools/update_manifest_publish_race_test.dart` 与本 bug 无关。
