## BUG-2820 · 视频页拖入 .bdmv / BDMV 目录无反应
- **报告**：2026-10-01（用户：「拖动导入 .bdmv 好像没效果」）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/drag_drop/drop_classification.dart` 的 `classifyDroppedFiles` 只按扩展名分桶，`.bdmv` / `.mpls` / `.clpi` 不在任何白名单里 → 落 `unknown` → `decideDropIntent` 视频表面返回 `unsupportedSurface`/`ignore`，页面静默。拖盘里的 `.m2ts` 则被当单个视频导入成一条叫 `00001` 的碎片；拖 `BDMV` 目录会把 `BDMV` 本身登记成来源（盘根在来源之外，扫描认不出盘）。真实盘 `E:\`（COSMIC_PRINCESS_KAGUYA）与拷贝 `D:\video\Cosmic Princess Kaguya\` 实测同样症状。
- **[x] ① 已修复** — 分类层新增 `DroppedFiles.blurayDiscs`（盘内文件按路径形状反推盘根 `blurayDiscRootForFile`；目录由 widget 层注入 `blurayDiscRootForDirectory`）与 `videoSourceFolders`（盘根优先、`BDMV` 目录/盘根不重复登记）；视频表面 `videoSourceFolders` 非空即 `addFolderAsSource`；`home_video_page.dart` 接线。真盘探针：盘根 / `BDMV` / `index.bdmv` / `STREAM\00001.m2ts` 五种拖法都登记到盘根，扫描入库一条正片（`BDMV\PLAYLIST\00001.mpls`）。
- **[x] ② 已加自动化测试** — `fushi/test/media/drag_drop/drop_classification_test.dart`（Blu-ray discs 组）、`fushi/test/media/drag_drop/drop_decision_test.dart`（video/books 表面三条）。
- **备注**：同批顺带：AACS 加密码流在交给 libmpv 前识别并给出明确原因（`bluray_encryption.dart`），此前是黑屏/报错不明。Fushi 不解密受保护光盘。
