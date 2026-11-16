## BUG-4699 · EPUB（含纯图漫画）导入整本读进内存并缓存全部解压内容，2 GiB 以上必然内存耗尽
- **报告**：2026-11-15（漫画 zip 导入排查衍生；用户拍板「修成流式 / 按条目读取」）
- **真实性**：✅ 真 bug（沿代码路径确认 + 测试量化）。`packages/fushi_engine/lib/epub/epub_parser.dart:85`（旧行号）
  `parseSyncFromPath` 先 `readAsBytesSync` 整本读入，`_decodeVerified`（旧 :46）为做 CRC 把**每个**条目解压缓存在
  `ArchiveFile` 上，`_extractArchive`（旧 :378）再从内存写盘：峰值≈文件体积 + 全部解压内容。纯图 EPUB 漫画导入
  （`MangaArchiveImporter` 的探测与导入两处）与普通 EPUB 导入（`epub_importer.dart`）都走它。`_readOpfMetadataSync`
  （旧 :109，导入前查语言 / 标题）同样整本读入并解压全部条目，只为读两个 XML。
- **[x] ① 已修复** — `parseSyncFromPath` 用 `InputFileStream` 只读中央目录，条目逐个经 `extractZipEntryToFile`
  原生分块解压落盘；`native_zip.dart` 的 `writeZipEntryStreaming` / `extractZipEntryToFile` 新增 `verifyCrc32`，
  边写边用 Rust `ffcCrc32` 续算，CRC 校验语义（HBK-AUDIT-106）不变；zip 层失败统一抛 `EpubArchiveCorruptException`，
  本次新建的解压目录随之删除。`_readOpfMetadataSync` 只解压 container.xml 与 OPF（各自核 CRC）。没有新增原生代码
  （复用既有 dart:io 原生 zlib 与 fushi_compute CRC）。提交见 PR。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/epub/epub_archive_corrupt_test.dart`：CRC 坏条目抛类型化
  异常且不留半成品目录；512 MiB 条目的 EPUB 经 `parseSyncFromPath` / `readTitleSync` 峰值 RSS 增长 < 128 MiB。
- **备注**：内存里的 `parseSync(bytes)` 入口（调用方已持有字节）不变。
