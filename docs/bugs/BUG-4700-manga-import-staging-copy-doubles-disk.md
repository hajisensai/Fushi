## BUG-4700 · 漫画导入从暂存目录拷贝进书目录，大包磁盘峰值是包体积的三倍
- **报告**：2026-11-15（用户反馈「不能导入 2G 以上的 .zip」排查衍生；用户拍板「另开一单，改成移动」）
- **真实性**：✅ 真 bug（沿代码路径确认）。`packages/fushi_engine/lib/media/manga/manga_importer.dart:225`（旧行号）
  `copyMangaArtifacts` 对所有来源一律 `src.copy(dest)`。压缩包导入（`manga_archive_importer.dart` 的 staging）、
  PDF / EPUB 转漫画（`fushi/lib/src/media/manga/book_format_rebuild.dart` 的暂存目录）、远端来源镜像与 mokuro.moe
  下载的解包目录都是**自己建、导完即删**的临时目录，却仍整份拷贝：导入 4 GiB 的包磁盘峰值 = 原包 + 暂存 4 GiB +
  书目录 4 GiB，空间紧的平板会在拷贝中途写满。
- **[x] ① 已修复** — 新增 `MangaPageSource { borrowed, disposable }`，随 `importFromImageFolder` /
  `importFromMokuroPath` / `copyMangaArtifacts` 传递，默认 `borrowed`（用户目录只拷不动）。`disposable` 时
  `MangaImporter.movePageFile` 同卷 rename，跨卷（EXDEV / ERROR_NOT_SAME_DEVICE）回退「拷贝 + 删源」，其它错误照常抛；
  同一源图被多页引用时第二次起从书目录那份拷。压缩包导入、书本格式重建、远端镜像（三处）、mokuro.moe 下载改传
  `disposable`。提交见 PR。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/manga_importer_test.dart` 组「page transfer into the book
  directory」（disposable 移动且逐字节一致、borrowed 原样保留、重复引用、覆盖旧产物（重建）、`importFromImageFolder`
  默认不动用户目录）。
- **备注**：跨卷回退分支没有自动化覆盖（单机测试造不出两个文件系统）；本机 Windows 实测 C:→D: 的 `File.rename` 抛 errorCode 17（ERROR_NOT_SAME_DEVICE），同卷 rename 覆盖已存在目标正常，与判据一致。
