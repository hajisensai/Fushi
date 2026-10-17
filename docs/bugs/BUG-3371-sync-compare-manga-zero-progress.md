## BUG-3371 · sync-compare-manga-zero-progress
- **报告**：2026-10-14（用户：两设备不同步时的「本地 / 远端」选择弹窗缺详细信息，漫画两侧都是 0.0%，实际已读一半，也没有具体页数）
- **真实性**：✅ 真 bug，且云通道还会丢进度。页式书（漫画 / PDF）`reader_positions.sectionIndex` 是 0-based 页码、`chaptersJson='[]'`，同步链路却一律按 EPUB 章节字符表折算：
  - 显示：`fushi/lib/src/sync/sync_compare_dialog.dart` `_fetchCompareData` 本地列 `toExploredCharCount` + `_fractionOf`（互联远端列）对空字符表恒得 0 → 两侧恒 0.0%；条目也没有页码字段。
  - 数据：`fushi/lib/src/sync/sync_manager.dart` `_handleExport` 导出 `exploredCharCount=0, progress=0`；`_handleImport` 经 `fromExploredCharCount` 空字符表恒返回 `sectionIndex 0` → 云通道（WebDAV / Drive 等）在冲突弹窗选「远端」或自动导入时，把读到一半的漫画重置回第 1 页。互联通道原样搬 `sectionIndex`，数据不受影响，只有显示错。
- **[x] ① 已修复** — 新增 `fushi/lib/src/sync/paged_book_sync_position.dart`（页式书判定 / 总页数 / 按页分数 / 页码钳制，在线漫画 `chapterCount` 是章数故不折算）；云通道 wire 对页式书把 `exploredCharCount` 当 0-based 页码（ッツ 不认识漫画 / PDF，无兼容面），导入原样落页码；对比弹窗条目新增 `localPage` / `remotePage` / `pageCount`，卡片在百分比下显示「第 X / Y 页」（在线漫画只显示页码）。
- **[x] ② 已加自动化测试** — `fushi/test/sync/paged_book_sync_progress_test.dart`（对比数据页码与分数、云导入不重置、越界钳制、云导出写页码、在线漫画不折算）。
- **备注**：修复前已导出到云端的漫画进度文件 `exploredCharCount` 恒为 0，修复后读出来是第 1 页（如实反映云端内容）；下一次从有进度的设备导出即纠正。
