## BUG-5284 · media-title-crc-suffix-not-cleaned
- **报告**：2026-11-23（用户：书库标题带导入文件名的残留，如漫画「週に一度クラスメイトを買う話 ～ふたりの時間、言い訳の五千円～ 2 [e0914585]」、
  epub「… [69c3d7b2].epub」；要求全媒体一份实现）
- **真实性**：✅ 真 bug。「什么是文件名里的 CRC 标签 / 扩展名」散在各处、各写各的正则、口径互相矛盾：
  书族显示层 `fushi/lib/src/media/display_title_hash_suffix.dart:17`（旧）只认**小写**、**方括号**、**一段**
  （`[ABCD1234]`、`(e0914585)`、`[..][..]`、`… [crc].epub` 原样上屏）；分卷键
  `packages/fushi_engine/lib/media/collections/book_series_key.dart:130`（旧 `_hashSuffix`）只认一段方括号；追踪检索词
  `packages/fushi_engine/lib/media/tracking/local_title_clean.dart:52`（旧 `_fileExtension`）只有书 + 少数视频容器；下载版本分组
  `packages/fushi_engine/lib/media/video/download/video_resource_version_groups.dart:50/80`（旧）各写一份。视频标题是原始文件名直接入库
  （如 `fushi/lib/src/media/video/external_video_ingest.dart:95`、`fushi/lib/src/media/source_library/source_library_scanner.dart:3197`），
  写入单点 `packages/fushi_core/lib/src/database/database_prefs_media.part.dart` `upsertVideoBook` 不清洗。
  实库（只读）`epub_books` 145 行里 79 行标题以 CRC 结尾，`srt_books` / `video_books` 0 行。
- **[x] ① 已修复** — 唯一实现 `packages/fushi_core/lib/src/utils/media_title_clean.dart`（引擎入口
  `packages/fushi_engine/lib/media/titles/media_title_clean.dart` 转出；放 core 是因为存量清理是 schema 迁移步）：显示层
  `cleanImportedTitle`（末尾已知扩展名 + 末尾一段或多段 8 位十六进制 `[..]` / `(..)`，大小写都认；出版社 / 版本标签、特典短篇、
  `『』`、卷号不动；清空则原样）+ 检索键层原语（`kImportedTitleFileExtensions` / `kCrcHexSource` / `kCrcTagSource` /
  `trailingCrcTagsPattern` / `isCrcHex`）。分卷键、追踪检索词、下载版本分组、书族显示层改用它（CRC 与扩展名都取并集）。
  视频：`upsertVideoBook` 写入单点清洗（导入 / 来源扫描 / 下载管线 / 互联登记全覆盖），`recordVideoImportActivity` 的活动标题同口径，
  v172 迁移清存量 `video_books.title`（幂等；用户改名 `updateVideoBookTitle` 不清洗）。
  **书名（`epub_books` / `srt_books`）不改存储**：`title` 是身份（`bookKey = sanitizeTtuFilename(title)`、统计聚合键
  `reading_statistics.title`、同步资产键、来源扫描「已导入」判定 `SourceLibraryScanner.predictTitle`），改写会让重扫重复导入、
  统计 / 同步分叉；书族只在显示出口清洗（BUG-4898 同一条红线），用户 override 不清洗。提交哈希：见分支提交记录。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/media/titles/media_title_clean_test.dart`（真实书名、`86` / `Catch22`、
  `(電撃文庫)`、BOOK☆WALKER 特典短篇、判据边界、幂等、扩展名表 ⊇ 视频 / 音频导入扩展名、三个消费方共用判据）；
  `packages/fushi_core/test/media_title_clean_migration_test.dart`（写入单点清洗、改名不清洗、v172 迁移清视频不碰书、幂等）；
  `fushi/test/media/display_title_hash_suffix_test.dart` 按并集判据更新。
- **备注**：音乐曲名的文件名兜底在 Rust 扫描器（`native/fushi_music/src/scan.rs` `file_stem`），Dart 实现管不到，未改；
  游戏名不来自文件夹名；`store_series_annotation.dart` / `music_metadata_text.dart` / `video_filename_parser.dart` 与本判据
  没有重叠原语（书店注记 / 音乐版本注记 / 引擎文件名解析器自带括号剥离），未动。
