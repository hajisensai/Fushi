## BUG-2332 · 云盘同步后端完全不同步漫画（上传静默跳过、下载按 EPUB 导入失败）
- **报告**：2026-09-09（用户：同步后端缺少同步漫画）
- **真实性**：✅ 真 bug。漫画的互联（局域网 host/client）通道早已完整，缺口全在**云盘**侧（Google Drive / WebDAV / OneDrive / Dropbox / FTP / SFTP 共用同一套 SyncManager + SyncOrchestrator 路径），另有一条互联域的漏网入口：
  - 上传：`fushi/lib/src/sync/sync_manager.dart:745` `_exportContentIfMissing` 恒调 `repackageExtractedEpub`；漫画书目录没有 EPUB 根 → `resolveExtractedEpubRoot` 返回 null → `built=false` → **静默不上传**，漫画在所有云盘后端永远传不上去。
  - 下载：`fushi/lib/src/sync/sync_orchestrator.dart:1593` `importRemoteBookFolder` 恒走 `EpubImporter.importFromPath`，即使包在云上也导不回来。
  - 对比弹窗下载：`fushi/lib/src/sync/sync_compare_dialog.dart:857` 互联分支恒走 `EpubImporter`，缺书架页 `_importRemoteBookFile` 早有的漫画内容嗅探 → 从「同步对比」下载互联漫画必失败。
  - 对比弹窗可下载判据：`fushi/lib/src/sync/sync_compare_dialog.dart:270` 用 `live?.hasContent`，而 host 对漫画恒 `hasContent=false`（那是 EPUB 内容树判据，漫画走 `hasMangaContent`）→ 互联漫画在对比弹窗里连下载入口都不出现。
- **[x] ① 已修复** — 沿用互联批次既定契约（漫画包与 EPUB 共用同一个 `<title>.epub` 资产名，导入侧按**内容**嗅探 zip 根 `manga.json` 分流，扩展名不参与判定），云盘侧因此不需要第二套命名：内容探针 / `getRemoteBook` / 对比弹窗的「远端有无内容」判据全部零改。四处改动：push 按 `BookFormat` 选打包器（并显式跳过无内容通道的 PDF）、pull 与对比弹窗下载加内容嗅探、对比弹窗可下载判据并上 `hasMangaContent`。
- **[x] ② 已加自动化测试** — `fushi/test/sync/cloud_manga_content_sync_test.dart`（4 条：push 上传的字节确为漫画包且资产名为 `<title>.epub`；PDF 零上传；pull 按内容落库成 `format=manga` 且页图落盘、bookKey 取远端资产名不带临时时间戳；同名 `.epub` 装真 EPUB 时仍走 EPUB 导入无回归）+ `fushi/test/sync/sync_compare_live_book_test.dart` 新增「远端独有的互联漫画同样可下载」（真起 `FushiSyncServer`，host 返回 `hasContent:false, hasMangaContent:true`）。
- **备注**：漫画阅读进度不在本缺口内——漫画与 EPUB 共用 `reader_positions`，进度/封面/标签/per-book CSS 都走格式无关的通用路径，已覆盖。向后兼容取舍与互联批次一致：旧版 client 从云盘下到漫画包会走 EPUB 导入失败、如实报错（不静默）。
