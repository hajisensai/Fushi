## BUG-4370 · 漫画导入框选纯图 EPUB 文件夹识别不到；批量导入不归合集
- **报告**：2026-10-29（用户：QQ 群反馈 iycDWb7ys6，fushi-bot 代提交）
- **真实性**：✅ 真 bug（读码定位，未在用户原始文件夹上复现：反馈没给文件夹清单 / 平台 / 日志）。
  - 判定分叉：同一个「一卷一个纯图 `.epub` + 散图（封面）」的文件夹，「导入文件夹」走来源库扫描的
    `planMangaFolders`，散图让位给单文件卷、逐卷导入（`packages/fushi_engine/lib/media/manga/manga_folder_plan.dart`
    的「散图让位」规则）；漫画导入框 / 拖入走 `classifyImportCarrier`，目录分支「有页图就是一卷页图目录」
    （`fushi/lib/src/media/import/import_carrier.dart:138` 旧行，判据 `mangaDirectoryHasPageImages` 只问
    `enumerateMangaPages(dir).isNotEmpty`，`fushi/lib/src/media/manga/import/manga_folder_batch.dart:76` 旧行），
    封面图一出现整个文件夹就被当成一卷只有封面的页图目录，那批 `.epub` 一本都不展开。
  - 不归合集：`importMangaBatchPaths`（`manga_folder_batch.dart:167` 旧行）导完不跑归组器，只有来源库扫描
    （`source_library_scanner.dart` 漫画分支）和书架页重载会调 `BookSeriesGrouper.groupAll`；从「导入」视图 /
    操作目录进来、书架页没挂着时这批卷就是散的。另外纯图 EPUB 落成漫画后原包不在书目录里，OPF 系列声明
    从没被留下，分卷名里没有系列线索时（每卷副标题不同）归组器无从判断。
- **[x] ① 已修复** —
  - 「散图让位」判据抽成引擎唯一函数 `mangaImageDirsClaimedByCarriers`（`manga_folder_plan.dart`），
    `planMangaFolders` 与 app 侧 `mangaDirectoryHasPageImages` 都问它：页图全是直接子层整卷文件的附属图时
    目录判成 `mangaBatchFolder`，两条导入路径对同一个文件夹给出同一种解释；子目录里的真页图不受影响。
  - `importMangaBatchPaths` 导进至少一卷后跑 `BookSeriesGrouper.groupAll` + 自动 AI 排序（与扫描器 / 书架页
    同一个归组器与门）。
  - `MangaArchiveImporter.importArchive` 的纯图 EPUB 分支把 OPF 系列声明（`encodeEpubSeriesMetadata`）经
    `MangaImporter.importFromImageFolder(sourceMetadata:)` 写进书行，归组器按声明归组。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/manga_folder_batch_test.dart`：散图 + 整卷文件同层判
  `mangaBatchFolder` 且与 `planMangaFoldersInDirectory` 同解释；子目录真页图 + 包仍是 `mangaFolder`；
  「封面 + 两卷纯图 EPUB」经导入框批量 / 拖入路径都逐卷导入并归进同一个合集；文件名无系列线索时按 OPF
  声明归组；一卷没进来不建合集；`mangaImageDirsClaimedByCarriers` 纯函数分支。
  `fushi/test/media/import/import_carrier_test.dart` 旧「页图优先」用例改名说明新口径。测试未在本分支运行，
  统一在合并后验证。
- **备注**：「拖入能导、按钮不能」两条入口在当前 develop 上实际都经 `classifyImportCarrier`，用户版本未知，
  拖入能导的原因（可能拖的是多选的 `.epub` 文件而不是文件夹）没法从反馈确认；修复不依赖这一点。未做真机复测。
