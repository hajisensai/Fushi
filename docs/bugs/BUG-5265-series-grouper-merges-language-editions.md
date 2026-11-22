## BUG-5265 · Book series grouper merges same-title editions in different languages into one collection
- **报告**：2026-11-22（用户：在讨论朗读声音按系列记时发现；日文版与台版《化物語》同名）
- **真实性**：✅ 真 bug。`BookSeriesGrouper` 的系列身份只有「书架 + 系列名」，不含语言：`_Volume.groupKey => '$shelf|${key.key}'`（`packages/fushi_engine/lib/media/collections/book_series_grouper.dart:646`），`key` 来自 `parseBookSeriesKey(title)` / OPF 声明的系列名（同文件 :224-230），`epub_books.language` 完全没参与。复现（内存库，4 本 EPUB：`化物語 上` / `化物語 下` 各一本 `ja`、一本 `zh-Hant`）：`groupAll()` 建出 2 个合集「化物語 上」「化物語 下」，**每个都是日文 + 中文各一本**——两个语言版本被并成同一系列。
- **[ ] ① 未修复** —
- **[ ] ② 未加自动化测试** — 建议加在 `fushi/test/media/collections/book_series_grouper_test.dart` 的 `BookSeriesGrouper` 组：同名不同语言的分卷不进同一合集；语言为空的书不因此被拆开（与现有行为一致）。
- **备注**：
  - 影响：同一合集里两个版本的卷号重复（两个「第 1 卷」），卷序自愈 / 首页续读 / 「读完第 N 卷推第 N+1 卷」会在两个版本间跳；合集级的「不追踪这个系列」会同时覆盖两个版本；有声书制作台的系列选角表（角色名两种写法）也会混在一起。朗读声音已在 PR #4216 按「系列 + 语言」记，不受此 bug 影响。
  - 修法方向（未拍板）：系列身份加上主语言子标签（`ja` / `zh`，语言为空的书归「未知」一格、不与有语言的拆开以免回归）；已存在的混合合集是否自动拆分要问用户（`origin == user` 的合集不能动，`rule` 的可以重算）。
  - 同一次复现还看到「化物語 上」「化物語 下」没被认成同一系列的上下卷（`上` / `下` 不当卷号），是另一个问题，未在本条处理。
