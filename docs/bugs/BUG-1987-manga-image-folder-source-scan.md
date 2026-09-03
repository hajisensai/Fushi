## BUG-1987 · 漫画来源扫描支持纯图片目录
- **报告**：2026-08-31（用户：漫画导入选择纯图片目录或其上级目录时扫描不到）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/source_library/source_library_scanner.dart:86` 的漫画来源白名单只有 `.mokuro`，`planScanFromFileList` 也只按单文件扩展名生成扫描项；虽然 `MangaImporter.importFromImageFolder` 已能递归导入页图，来源扫描器从未把纯图片目录交给它。
- **[x] ① 已修复** — 漫画本地来源会把扫描根自身的页图归成一卷；选择上级目录时，把每个含页图的直接子目录归成一卷。导入复用 `MangaImporter.importFromImageFolder`，补传 `sourceId`，并用 `DuplicatePolicy.skip()` 保持后台重扫幂等。提交：`a399d095df`。
- **[x] ② 已加自动化测试** — `fushi/test/media/source_library/source_library_scanner_test.dart` 覆盖扫描根自身、上级目录多卷、真实落库、`sourceId` 回填和重复重扫。提交：`a399d095df`。
- **备注**：网络漫画来源仍保持 `.mokuro` 整卷镜像边界；纯图片目录只对本地来源开放，因为导入器需要直接读取目录树。
