## BUG-5286 · Book series grouper merges same-title editions in different languages into one collection
- **报告**：2026-11-22（用户：在讨论朗读声音按系列记时发现；日文版与台版《化物語》同名）
- **真实性**：✅ 真 bug。`BookSeriesGrouper` 的系列身份只有「书架 + 系列名」，不含语言：`_Volume.groupKey => '$shelf|${key.key}'`（`packages/fushi_engine/lib/media/collections/book_series_grouper.dart:646`），`key` 来自 `parseBookSeriesKey(title)` / OPF 声明的系列名（同文件 :224-230），`epub_books.language` 完全没参与。复现（内存库，4 本 EPUB：`化物語 上` / `化物語 下` 各一本 `ja`、一本 `zh-Hant`）：`groupAll()` 建出 2 个合集「化物語 上」「化物語 下」，**每个都是日文 + 中文各一本**——两个语言版本被并成同一系列。
- **[x] ① 已修复** — `EpubBookSeriesFacts` 带上 `epub_books.language`；`_Volume` 记主语言子标签（`bookSeriesLanguageKey`），同一「书架 + 系列名」里出现两种以上已知语言时才按语言拆组（`_markLanguageSplits`），合集名加 ` (ja)` / ` (zh)` 后缀，同名播放列表不会把两个版本收回一处；已拆开的系列里语言未知的书留在外面（不知道归哪个版本）；只有一种已知语言的系列与修复前完全一样。已存在的混合合集不自动拆（已在合集里的书照旧不动，用户手动挪）。
- **[x] ② 已加自动化测试** — `fushi/test/media/collections/book_series_grouper_test.dart`：「同名不同语言的版本各建一个合集」「语言未知的书不因有语言的同名书被拆开」。
- **备注**：
  - 影响：同一合集里两个版本的卷号重复（两个「第 1 卷」），卷序自愈 / 首页续读 / 「读完第 N 卷推第 N+1 卷」会在两个版本间跳；合集级的「不追踪这个系列」会同时覆盖两个版本；有声书制作台的系列选角表（角色名两种写法）也会混在一起。朗读声音已在 PR #4216 按「系列 + 语言」记，不受此 bug 影响。
  - 同一次复现还看到「化物語 上」「化物語 下」没被认成同一系列的上下卷（`上` / `下` 不当卷号），是另一个问题，未在本条处理。
