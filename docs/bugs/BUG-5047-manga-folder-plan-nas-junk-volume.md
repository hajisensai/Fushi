## BUG-5047 · 漫画卷归组的 dart:io 入口把群晖 @eaDir 缩略图目录归成一卷（服务端库扫描 / 导入命令）
- **报告**：2026-11-20（路线图 #3722 第 3 节 c08 / c38 漫画侧遗留，BUG-4907 备注里点名）
- **真实性**：✅ 真 bug。`packages/fushi_engine/lib/media/manga/manga_folder_plan.dart:377`（修前）的
  `planMangaFoldersInDirectory` 递归列出全部文件后交给只看扩展名的 `planMangaFolders`：库根下 `@eaDir/<卷名>/SYNOPHOTO_THUMB_*.jpg`
  让 `@eaDir` 自成一卷纯页图目录，只有 `._cover.jpg` 的根被当成「根本身有页图」整棵合成一卷。调用方是无头服务端库扫描
  （`packages/fushi_server/lib/src/library_scanner.dart:713`）、服务端导入命令（`import_commands.dart:178` / `:345`）与
  书库回收（`book_library_prune.dart:534`）。app 源库扫描在列目录时按 `isSourceScanJunkPath` 过滤过，不受影响——
  同一棵 NAS 目录树在 app 与服务端归出的卷不一样。根因与 BUG-4907 相同：垃圾条目判据散在三处（扫描器认 `@eaDir`
  不认 `__MACOSX`，页图枚举只认这两个，卷归组一个都不认）。
- **[x] ① 已修复** — 判据收成一处 `packages/fushi_engine/lib/media/system_junk_entries.dart`
  （`isSystemJunkDirectoryName` / `isAppleDoubleFileName`，目录表并集）。`planMangaFoldersInDirectory` 枚举时跳过垃圾目录
  与 `._` 文件；`enumerateMangaPages` 与 app 的 `isSourceScanJunkPath` 改问同一份，删掉各自的私有表。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/manga_folder_plan_test.dart`「跳过 @eaDir / __MACOSX / 回收站目录与 ._
  资源叉」：修前 `imageFolders` 多出根目录（`._cover.jpg`）；`source_scan_integrity_test.dart` 补 `__MACOSX` 断言。
- **备注**：扫描器的垃圾目录表因此多认 `__MACOSX`，页图枚举多认回收站类目录，都是同类系统目录。
