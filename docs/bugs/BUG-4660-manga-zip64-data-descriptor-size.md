## BUG-4660 · ZIP64 数据描述符被按 4 字节读，条目大小读成 0，导入报损坏
- **报告**：2026-11-15（排查 BUG-4659「2G 以上 zip」时沿代码路径发现）
- **真实性**：✅ 真 bug（构造样本复现）。带数据描述符（通用位 3）的条目，archive 3.6.1 的 `ZipFile` 读完数据后
  把描述符里的大小按 4 字节读、覆盖 `uncompressedSize`（pub-cache `archive-3.6.1/lib/src/zip/zip_file.dart:125-126`）；
  ZIP64 描述符的大小字段是 8 字节，读出的「解压后大小」变成压缩大小的高 32 位（通常 0）。导入器的流式解压
  以 `ArchiveFile.size` 为声明大小（`packages/fushi_engine/lib/media/manga/manga_archive_importer.dart:1165` 旧行号），
  随即报「expands beyond its declared 0 bytes」。超过 4 GiB、由流式写出工具生成的包会中。
- **[x] ① 已修复** — 声明大小与 CRC 一律取中央目录（含 ZIP64 extra）记录（`_OpenedArchive.declaredSize` /
  `declaredCrc32`），预检、清单读取与流式解压同一来源。提交见 PR。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/manga_archive_importer_test.dart`
  「ZIP64 records with 8-byte data descriptors import byte-for-byte」（小条目写出完整 ZIP64 记录形状：本地头 / 中央目录
  0xFFFFFFFF + ZIP64 extra、8 字节描述符、ZIP64 EOCD + 定位器）。
- **备注**：
