## BUG-1893 · 存储页书籍条目不显示有声书音频大小
- **报告**：2026-08-27（用户：「存储里面的书籍和有声书里面没有显示有声书音频大小」）
- **真实性**：✅ 真 bug，但不是「漏扫 audiobooks 目录」——**类目总量是对的**（`storage_usage_service.dart:178-216` 的类目根含 `audiobooks`，`_scanBooks` 的 `sizes[0]` 扫整树）。错的是**明细行口径**：每本书的体积用 `audiobookPersistDirPath(docs, key)`（`:297-300`）= `<documents>/audiobooks/fnv1a32Hex(utf8(key))` **纯哈希派生**，而音频真实路径的真相源是 DB 的 `Audiobooks.audioRoot` / `audioPathsJson` 与 `SrtBooks.audioRoot` / `audioPathsJson`（`packages/fushi_core/.../tables.dart:72` / `:102`）。三类音频因此在条目里恒为 0：
  - **A（主因）** 互联/同步拉来的有声书落**明文目录**：`fushi/lib/src/sync/sync_asset_package_service.dart:288-290` 用 `Directory(p.join(audioDatabaseRoot.path, _safeDirName(bookKey)))` 并把它写进 `audioRoot`（`:320-323`，standalone 分支 `:394-396` 用 `uid`）。扫描端去找哈希目录 → 不存在 → 明细只剩 `extractDir`（EPUB 正文几百 KB），几 GB 音频全掉进「类目总量 − 明细之和」的差额里，条目上看不见。
  - **B** standalone 字幕/有声书**连行都不出**：`SrtBooks.bookKey` 恒空串（`tables.dart:112-113`），被 `settings_schema_storage.dart:48` 的 `if (srt.bookKey.isEmpty) continue;` 过滤掉；条目又只来自 `getAllEpubBooks()`（`:38-39`）。这类书既无体积也无删除入口。
  - **C** 桌面「引用原文件」导入的音频在 app 目录外（`book_import_dialog.dart:942` / `audiobook_import_dialog.dart:676` → `AudiobookStorage.syncAudioFiles(..., copy: false)` → `audiobook_storage.dart:244` 直接存原始绝对路径），总量也扫不到，页面还没有任何说明。
  既有守卫 `test/storage/storage_usage_service_test.dart:87-133` 只覆盖了哈希目录这一种落盘形态，所以 A/B 一直没被咬住。
- **[x] ① 已修复** —
  - 明细口径改为「**DB 真实路径 ∪ 哈希派生目录**」，不是二选一替换——存量本地导入就是哈希目录形态，砍掉就是 Never break userspace 的反面。新增纯函数 `resolveBookStoragePaths()` 把一本书拆成 `counted` / `external` 两组，配 `_dedupeNestedPaths()` 去重去嵌套（同步导入的书 `audioRoot` 是目录、`audioPathsJson` 是它下面的文件，本地导入的哈希目录又常与 `audioRoot` 同路径，不去嵌套会把同一堆字节数两三次）。
  - 音频路径只有落在书籍类目根之内才计入体积，落在外面的进 `externalPaths`——保住「明细之和 ≤ 类目总量」这条不变式（类目总量同样扫不到外部路径）。
  - `bookKey` 为空的 standalone `srt_books` 作为**独立条目**出行，新增 `StorageEntryKind.srtBook` 接对应删除原语（此前这类书无行、无删除入口）。
  - C 类外部引用在条目副标题上补一句说明（新 i18n key `storage_entry_external_audio_hint`，en/zh 已译，其余 15 语暂回落英文）：不说清楚的话条目只显示正文那几百 KB，用户会以为音频丢了。
- **[x] ② 已加自动化测试** — `fushi/test/storage/storage_usage_service_test.dart` 与 `fushi/test/pages/storage_usage_view_test.dart` 扩展（明文目录形态、standalone srt 条目、外部引用路径、去嵌套不重复计数），两文件整套 29 条通过。
  变异实测：把 `resolveBookStoragePaths` 里的 `book.audioPaths`（DB 真实路径）删掉、退回纯哈希口径 → 精确红「同步导入的明文音频目录计进明细」与「外部音频不计体积但如实报进 externalPaths」2 条，其余全绿；还原后 sha256 与变异前一致（`b9a329dc1d71932c…`）。
- **备注**：本条只修统计与展示口径，没有改任何落盘位置（明文目录 vs 哈希目录两种形态继续并存，迁移不在本轮范围）。真机验证未做（用户已取消该环节）。
