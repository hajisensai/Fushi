## BUG-5399 · series-key-digit-name-dash-title
- **报告**：2026-11-23（BUG-5395 排查时发现：「86―エイティシックス― 3」的系列名被读成「86」）
- **真实性**：✅ 真 bug。`packages/fushi_engine/lib/media/collections/book_series_key.dart` `_splitVolumeSuffix` 把结尾成对的破折号段（`―…―` / `─…─`）一律当副标题剥掉，「86―エイティシックス―」剥完只剩「86」。合集名只有「86」，拿系列名去在线源搜（MangaBaka / Bangumi）也搜不到这部作品。
- **[x] ① 已修复** — 剥成对副标题前先看剩下的部分能不能单独当系列名（新增 `_namesSeriesAlone`：至少要有一个不是数字的字）。只剩数字时那段就是书名本身，不剥。正文有字时照常剥（「週に一度クラスメイトを買う話 ～ふたりの時間～」不受影响）。
- **[x] ② 已加自动化测试** — `fushi/test/media/collections/book_series_grouper_test.dart`「合集名保留原文写法；书名本身的数字不被当卷号吃掉」：`86―エイティシックス― 3` → 系列「86―エイティシックス―」、卷 3、与无卷号的第 1 卷同键；附对照用例。
- **备注**：已按「86」建好的合集照旧沿用（归组按成员认已有合集，`_collectionHoldingSeries`），不会重复建，合集名仍是「86」，要改名需用户手动改；新建的合集用整名。
