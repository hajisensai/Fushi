## BUG-1928 · 远端卡「从远端删除」文案谎称本地数据保留

- **报告**：2026-08-29（用户截图：「确定从远端删除「魔法少女ホロウィッチ！」吗？**本地数据保留**，
  此操作不可撤销。」＋「这里不应该本地数据保留」）
- **真实性**：✅ 真 bug（文案错，不是行为错）。
- **根因**：i18n key `sync_compare_delete_confirm` 被**三处共用**，而其中两处的真值是相反的：
  - `fushi/lib/src/sync/sync_compare_dialog.dart:927`（云盘/备份比较对话框）：本机通常确实还有
    一份，这句话是**真话**、有信息量；
  - `fushi/lib/src/pages/implementations/reader_history/remote.part.dart:972`（互联对端远端书卡）
    与 `home_video_page.dart:5286`（远端视频卡）：这两张卡**按构造**就是「本机没有的条目」——
    `dedupeRemoteBooks`（`fushi_library_host_service.dart:735`，调用点 `remote.part.dart:103`）
    把标题键已存在于本地的远端条目全部滤掉了。

  也就是说「本地数据保留」保留的是**空集**，读起来却像「删了本机还留着一份」；而确认之后
  `AppModelLibraryHostService.deleteBook`（`app_model_library_host_service.dart:642-667`）在对端是
  **彻底删除**：`_cleanupBookOnDisk` + `deleteEpubBook(tombstone: true)`（连带 readerPositions /
  bookmarks / srtBooks / audioCues / audiobooks + 写墓碑）+ `Directory(row.extractDir).delete(
  recursive: true)`（漫画就是全部页图）。**用户手上一份都不剩。**

  「行为错（应连本地一起删）」这条不成立：dedupe 保证了本机在这个入口下没有该书的任何行，
  「连本地一起删」是空操作。

- **[x] ① 已修复** — 1d2053fdf4。**不改**老 key 的值（那会污染比较对话框里的真话），另起两个说实话的
  对端专用 key。书和视频删的东西还不一样，所以分成两条：
  - `sync_peer_book_delete_confirm`：点明对端的文件与阅读进度会被永久删除、本机没有副本；
  - `sync_peer_video_delete_confirm`：点明对端**自己导入的原始视频文件会保留**
    （`deleteVideo` 只删库条目与 app 自己造的封面/字幕/上传副本）。

  两个 key 均补齐 17 语言真译（不是留英文占位）。
- **[x] ② 已加自动化测试** — `fushi/test/sync/peer_delete_confirm_wording_guard_test.dart`：
  远端书卡/视频卡各用自己的 key 且不得再引用 `sync_compare_delete_confirm`；比较对话框必须
  **保留**老 key；两个新 key 的 en/zh-CN/zh-HK 值里不得出现「本地数据保留」/「Local data is kept」。
  变异实测：把 `remote.part.dart` 改回老 key → 变红。
