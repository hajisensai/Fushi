## BUG-5194 · 加密 CBZ / CB7 / CBR 导入丢掉 `.mokuro` 文字层
- **报告**：2026-11-22（PR #4143 合并审查：加密包导入的自报缺口）
- **真实性**：✅ 真缺口（代码路径确认，未真机复现）。加密的 CBZ / ZIP 与 RAR / CB7 一样改走归档解包点（`packages/fushi_engine/lib/media/manga/manga_archive_importer.dart:539` `isEncrypted` 分流），`MangaSevenZipExtractor.extractImages` 只解页图扩展名（同文件 `:313` `includeExtensions: kMangaImageExtensions`）；包内 `.mokuro` 与包旁 sidecar（`:911` `mangaArchiveMokuroSidecarPaths`）只有未加密 ZIP 分支读（`:583` `_findMokuroCandidate`，吃 `package:archive` 的 ZIP 对象）。结果：带 Mokuro OCR 的加密 CBZ 能导入，但文字层静默丢失，只剩图片；CB7 / CBR 的 sidecar 也一直不读。
- **[ ] ① 未修复** — 方向：解包点分支解出 `.mokuro` 一起落进暂存目录，暂存目录按目录型 mokuro 导入（与 sidecar 同一份判据），让 ZIP / 解包点两条分支共用一套 mokuro 认定，而不是只给 ZIP 分支。
- **[ ] ② 未加自动化测试** — 待修时在 `fushi/test/media/manga/manga_archive_importer_test.dart` 加「加密 CBZ 内嵌 `.mokuro` / CB7 + sidecar 导入后 OCR 页存在」。
- **备注**：加密包导入本身（PR #4143）之前根本导不进，这不是回退；但导入成功却丢文字层是静默数据缺失，按 bug 登记。
