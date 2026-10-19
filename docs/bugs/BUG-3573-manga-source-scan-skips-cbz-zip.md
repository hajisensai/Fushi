## BUG-3573 · 漫画来源扫描跳过 .cbz / .zip 卷（显示 0 卷），漫画来源里的 .epub / .pdf 卷也被丢掉
- **报告**：2026-10-19（用户：外部用户反馈，`D:/MangaFushi/Veil/Veil（1）….zip` 等 7 个 zip 卷的漫画来源扫描结果「0 volumes」）
- **真实性**：✅ 真 bug。根因三处：
  1. `fushi/lib/src/media/source_library/source_library_scanner.dart:117`（旧 `kScanMangaArchiveExtensions`）手抄了一份只有 `rar` / `cbr` / `cb7` 的白名单，与 `fushi/lib/src/media/import/import_carrier.dart:84` 的载体真相源 `kMangaCarrierFileExtensions` 漂移：`.cbz` / `.zip` 卷被静默跳过；漫画来源里的 `.epub` / `.pdf` 被分进 `books`，又在 manga 分支整个丢掉。手动导入同一批文件完全正常。
  2. 同文件 `_importManga`：除重复之外的任何单卷异常都冒泡，中止整个来源，排在坏卷后面的卷全部不入库。
  3. 无头服务端 `packages/fushi_server/lib/src/library_scanner.dart` `_scanManga` 完全不收单文件卷，注释给的理由（「压缩包导入器还在 app 侧」）早已过时——`MangaArchiveImporter` 已在 `fushi_engine`。
- **[x] ① 已修复** — 单文件卷归组下沉进引擎 `planMangaFolders`（`carrierPaths` + 包旁 `.mokuro` sidecar 认领 `mokuroSidecars`，与载体同目录 / 祖先目录的散图不再成卷）；载体表 `kMangaArchiveFileExtensions` / sidecar 候选 `mangaArchiveMokuroSidecarPaths` 由引擎导出，导入器、app 手动导入载体表、app 来源扫描、服务端库扫描四处同源。app 扫描单文件卷经 `classifyImportCarrier`（与手动导入同一判据：`.zip` / `.epub` 开包定性，词典包 / 文字书跳过，`.pdf` 走 `importMangaFromPdf`）；逐卷失败汇总进 lastScanError（与视频分支 BUG-2570 同语义）；网络来源连同 sidecar 一起镜像。服务端漫画根收 cbz/zip/rar/cbr/cb7/纯图 EPUB（PDF 栅格化只在 app 侧，服务端不收）。提交见本分支 `worktree-fix-manga-source-zip-cbz`。
- **[x] ② 已加自动化测试** — `fushi/test/media/source_library/source_library_scanner_test.dart`（用户实报布局 zip/cbz 入库 + 重扫去重、词典 zip / 文字 epub 跳过、坏包不中断、cbz+sidecar 只一卷、载体表同源、书籍来源不受影响、封面不成卷）；`fushi/test/media/manga/manga_folder_plan_test.dart`（引擎归组单文件卷 / sidecar / 让位规则）；`packages/fushi_server/test/library_scanner_manga_test.dart`（服务端 zip/cbz 入库、词典 zip 跳过）。
- **审查追加（同分支，根因修复）**：
  1. 重扫时已在库的包每次整包解压再判重复 → 卷身份改走来源扫描索引（引擎 `BookSourceIndex`，app 与服务端同一个偏好键 `media_source_scan_index_<id>`，不升 schema），已登记的卷不开包、不下载；该键不进 Profile 快照（`profile_keys.dart`）。
  2. 判过「不是漫画」的 `.zip` / `.epub`（词典包、文字书）每次重扫重判、网络来源每次重新下载 → 索引里加负向表（源相对路径 → 内容指纹：ETag 优先，否则字节数 + 修改时刻；本地 stat，远端取 SFTP / FTP / WebDAV / AList 列目录元数据），指纹不变就跳过。
  3. 文字 EPUB 定性在 UI isolate / 服务端事件循环上同步整本解析 → `looksLikeImageArchiveInBackground`（`Isolate.run`）。
  4. 重复只看标题：`系列A/Vol 1.cbz` 之后的 `系列B/Vol 1.cbz`、同目录 `Vol 1.pdf` 被静默跳过 → 重复判据 `isDuplicateSourceBook`（标题 + 来源路径）：本来源另一个仍在场的文件已认领 → 按 `DuplicatePolicy.suffix()` 换名另导；本来源旧行 → 认领；手动导入 / 别的来源 → 按重复跳过（app 不认领无来源行）。
  5. zip 炸弹上限按中央目录声明大小累计、页条目整条进内存 → 条目从本地头流式 inflate 直写磁盘，按实际字节强制单条 256MB / 总量 2GB，实际字节必须等于声明，CRC 分块累计；加密 / 非 store·deflate 条目拒绝（`manga_archive_importer.dart` `_ZipEntryStreamer`）。
  6. 归组规则：包旁散图让位改为「每个页图目录的子树都有包」才成立（散装章节目录不再因隔壁一个包整卷丢失）；对账枚举 `enumerateBookSourceRelPaths` 补上单文件卷。
  - 测试：`fushi/test/media/source_library/source_library_scanner_test.dart`、`source_library_scanner_network_test.dart`、`fushi/test/media/manga/manga_archive_importer_test.dart`、`fushi/test/media/manga/manga_folder_plan_test.dart`、`packages/fushi_engine/test/media/source_library/book_library_prune_test.dart`、`packages/fushi_server/test/library_scanner_manga_test.dart`；关键修复均做过变异实测（回退即红）。
  - 仍未覆盖：EPUB 分支的 `EpubParser.parseSyncFromPath` 整包读入并整条解压算 CRC，没有按实际字节的上限；app 书籍来源（`_importBooks`）的重复判据仍只看标题。
- **备注**：同一位用户还报了「CBZ 里是 AVIF 页图不支持」——另一个独立问题：页图基集 `kImageExtensionsBase` 无 `.avif`，且 Rust `fushi_compute` 的 image crate 未开 AVIF 解码、`package:image` 4.3 也不支持，单补白名单只会把报错从「no images」换成「Could not decode manga page」。需要先定 AVIF 解码依赖（libdav1d C 库 vs 纯 Rust + MPL-2.0 容器解析）再另起一条修。
