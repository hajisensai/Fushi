## BUG-4916 · 本地页图卷枚举把群晖 @eaDir 缩略图、__MACOSX 与 ._ 资源叉当成漫画页
- **报告**：2026-11-20（路线图 #3722 第 3 节 c08 漫画侧遗留，并入组 c38）
- **真实性**：✅ 真 bug。`packages/fushi_engine/lib/ocr/manga_ocr_folder_job.dart:207` 的 `enumerateMangaPages`
  递归下钻 6 层、只按扩展名收文件：群晖 `@eaDir/<页名>/SYNOPHOTO_THUMB_*.jpg`（每页一组缩略图）、macOS 解包留下的
  `__MACOSX/` 与 `._001.jpg` AppleDouble 资源叉都是图片扩展名，全被当成真页。它是导入器
  （`manga_importer.dart:160` / `:663`）与 OCR 任务共用的页序真相源，结果是卷里插进缩略图 / 打不开的空白页、
  页数翻倍、OCR 白跑。压缩包导入路径（`manga_archive_importer.dart:688`）早就跳过 `__MACOSX` / `._`，目录路径漏了。
- **[x] ① 已修复** — 枚举跳过 `@eaDir` / `__MACOSX` 目录（不分大小写，`kMangaPageScanSkippedDirNames`）与 `._` 开头
  的文件（`isMangaAppleDoubleFile`）。
- **[x] ② 已加自动化测试** — `fushi/test/ocr/manga_ocr_folder_job_test.dart`「跳过群晖 @eaDir、__MACOSX 与 ._
  AppleDouble」：根目录与子目录各放一组垃圾，只剩两张真页。去掉修复后多出 5 条。
- **备注**：批量导入的归组扫描 `packages/fushi_engine/lib/media/manga/manga_folder_plan.dart` 的
  `planMangaFoldersInDirectory` 同样走进 `@eaDir`，会把 `@eaDir/<页名>/` 当成一卷纯页图目录；不在本组文件清单，
  已记进 c38 PR 的遗留。
