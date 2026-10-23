## BUG-3663 · 结尾 `<系列名>` 被当出版标签丢掉，日文轻小说整套散在书架上
- **报告**：2026-10-23（用户：应用内反馈 n4KC1azJvw，Android 3.0.0「EPUB 系列各卷被拉平到书架」，截图里『青春ブタ野郎は…の夢を見ない<青春ブ…』各卷散开）
- **真实性**：✅ 真 bug。`parseBookSeriesKey`（`packages/fushi_engine/lib/media/collections/book_series_key.dart:62`）卷号匹配不上时用 `_trailingLabel`（`:43`）把结尾 `<…>` / `(…)` 整段剥掉丢弃，系列名恰好就在里面；各卷副标题不同，key 互不相同，`BookSeriesGrouper`（`book_series_grouper.dart:101`）就不归组。
- **[x] ① 已修复** — 新增 `_seriesFromTrailingLabel`：结尾标签内容（≥2 字）是正文的**真前缀**时，它就是系列名 / key；正文末尾的卷号照常读。`(電撃文庫)`、`<上>` 不是正文前缀，照旧按出版标签处理；不用「多卷共享同一标签」当判据（会把同文库不同作品并成一组）。
- **[x] ② 已加自动化测试** — `fushi/test/media/collections/book_series_grouper_test.dart`（青ブタ形态正例、带卷号正例、`(電撃文庫)` / 单字 `<上>` / 标签与正文相同三条反例）。
- **备注**：每卷副标题不同、也没有结尾系列标签的作品（『ココロコネクト ヒトランダム / キズランダム …』）靠书名分不出，需读 OPF `calibre:series` / `belongs-to-collection` 或按文件夹归组——属需决策项，未在本提交实现。
