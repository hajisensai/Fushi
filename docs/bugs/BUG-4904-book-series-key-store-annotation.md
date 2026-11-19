## BUG-4904 · 书店写法「卷号<系列名> (文库名)」的分卷导入后不归合集
- **报告**：2026-11-15（用户：拼贴审查设计稿「最近添加」系列合并卡，书名「Re：ゼロから始める異世界生活 1<Re：ゼロから始める異世界生活> (MF文庫J)」）
- **真实性**：✅ 真 bug。Kindle / BookWalker 轻小说 dc:title 一律是「正文 + 卷号 `<系列名>` `(文库名)`」，
  分卷归组判据 `parseBookSeriesKey` 两条路都认不出：
  `_seriesFromTrailingLabel` 只看**最后一个**括号（`packages/fushi_engine/lib/media/collections/book_series_key.dart:148`
  `if (open < label.start || open >= close) return null;` 前取的 `open` 是 `(MF文庫J)` 的左括号），`MF文庫J` 不是正文
  前缀 → 不当系列名；卷号路径 `_splitVolumeSuffix` 只剥一层结尾标签（`book_series_key.dart:74`），剥掉 `(MF文庫J)` 后
  结尾仍是 `<…>`，卷号读不出，于是整串（含卷号与注记）原样成了系列键（`book_series_key.dart:104`）——每卷键互不相同，
  `BookSeriesGrouper` 一卷也并不进合集。显示侧 H4 的 `stripStoreSeriesAnnotation` 已认这种写法，但只在
  `package:fushi` 里，引擎不能引用，判据成了两份、归组那份缺。
- **[x] ① 已修复** — 注记判据下沉到引擎 `packages/fushi_engine/lib/media/collections/store_series_annotation.dart`
  （`splitStoreSeriesAnnotation` / `stripStoreSeriesAnnotation`，唯一实现）；`parseBookSeriesKey` 先走
  `_seriesFromStoreAnnotation`：系列名取尖括号里的原文写法，卷号从正文末尾读。`fushi/lib/src/media/display_title_store_series.dart`
  删掉自己的正则与归一化，改为引用 / 再导出引擎实现。提交哈希：收尾阶段统一提交后补。
- **[x] ② 已加自动化测试** — `fushi/test/media/collections/book_series_grouper_test.dart`「书店系列注记」组（真实书名、全角括号、
  无卷号外传、与普通写法同键、`<上>` / `<限定版>` / 系列名不是前缀不误伤）；显示侧沿用
  `fushi/test/media/display_title_store_series_test.dart`。
- **备注**：已导入的书 `title` 不变，归组键是导入 / 书架重载时现算的，书架下次重载映射即按新键归组。
