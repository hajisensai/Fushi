## BUG-414 · 远端有声书下载404(client重算bookKey丢弃host真实key)
- **报告**：2026-06-24（用户：750a 回归）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/pages/implementations/reader_history/remote.part.dart:335`（原 `final String remoteBookKey = sanitizeTtuFilename(book.title);`）。
  - 真机互连下载远端有声书报 `404 Not found: GET /api/library/audiobooks/<bookKey>`。
  - 同函数里 EPUB 下载（`remote.part.dart:251` `getRemoteBook(book.downloadId, ...)`）用 `book.downloadId`（= `RemoteBookInfo.bookKey ?? title` = host JSON 传来的**真实 bookKey**，`hibiki_library_host_service.dart:171/178`），所以 EPUB 成功；有声书却丢弃 `book.bookKey` 自己 `sanitizeTtuFilename(book.title)` 重算。
  - host 端自洽：`Audiobooks.bookKey == EpubBooks.bookKey`，`listAudiobooks` 发 `RemoteAudiobookInfo(bookKey: r.bookKey, ...)`（`app_model_library_host_service.dart:387`，真实 key）。client 重算只在 `sanitizeTtuFilename(host title) == host bookKey` 时才相等——书名重名加后缀 `(2)`/旧数据迁移时破→算出 host `Audiobooks` 表不存在的 key→404。非 NFC/NFD、非 URL 编码问题。
  - 第二处同隐患：`sync_compare_dialog.dart:_downloadLiveAudiobookFor`（约 :752）先 `sanitizeTtuFilename(entry.title)` 再去 `listRemoteAudiobooks` 里 `any` 比对、miss 静默跳过——同样会算出错 key 漏下音频。
- **[x] ① 已修复** — `remote.part.dart:335` 改 `final String remoteBookKey = book.downloadId;`（与 EPUB 下载同源，消除不对称）；`sync_compare_dialog.dart:_downloadLiveAudiobookFor` 改为按 `title` 在 `listRemoteAudiobooks()` 清单里找该书的真实 `RemoteAudiobookInfo.bookKey` 下载（不再 sanitize 重算 + any 比对）。提交：28b2aa15f
- **[x] ② 已加自动化测试** —
  - `hibiki/test/pages/reader_remote_interconnect_test.dart`：BUG-406 有声书接线用例改为 `_FakeRemoteBookClient` 设 `bookKey = 'Vol_1_2_Audio_2'`（≠ `sanitizeTtuFilename(title)`，模拟重名/迁移），断言 `fetchedAudiobookKeys == [hostAudiobookKey]` 且 `!= [sanitize(title)]`——撤修复（改回 `sanitizeTtuFilename(book.title)`）转红。
  - `hibiki/test/sync/sync_audiobook_download_wiring_guard_test.dart`：源码扫描守卫改为钉死两处 `book.downloadId` / 清单 `a.bookKey` 用法，并 `isNot(contains('sanitizeTtuFilename(book.title)'))` / `isNot(contains('sanitizeTtuFilename(entry.title)'))`，禁止退回重算。
  提交：28b2aa15f
- **备注**：`sync_compare_dialog` 路径 `SyncCompareEntry`（远端独有书 `bookKey==null`）无可直接用的 bookKey 字段，故用 host 清单条目（`bookKey` 真实 + `title=srt.title`）按 `title == entry.title` 匹配取真实 key——host 端 EPUB/有声书自洽（同一本书 title 一致），是该路径最忠实的「用真实 key」修法。
