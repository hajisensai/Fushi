## BUG-5051 · reader-stats-sheet-load-error-unhandled
- **报告**：2026-11-20（路线图 #3722 m5 / gap-vidmisc-5 + gap-mangamisc-8 附带项：「`then` 补 `onError`」）
- **真实性**：✅ 真 bug。`fushi/lib/src/reader/reader_statistics_sheet.dart:346`（修前）`widget.loadBookTotals().then(...)` 外面只包了 `unawaited`，没有 `onError`：阅读器 / 漫画 / 视频统计侧栏打开时读本书今日 / 累计（`loadStatFacts`）一旦抛错（库已关闭、查询异常），就是一个无人接的异步错误，落到 zone 的未处理错误里，错误日志里也没有可追的来源。
- **[x] ① 已修复** — `.then` 补 `onError`：记进 `ErrorLogService`（来源 `ReaderStatisticsSheet.loadBookTotals`），今日 / 累计停在空态（与加载中同一外观），侧栏其余实时读数照常。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_statistics_sheet_test.dart`「本书累计读取失败：记错误日志、停在空态、不抛未处理异常」：`loadBookTotals` 抛 `StateError`，断言无未处理异常、错误日志 +1、空态渲染。去掉 `onError` 时该用例因未处理异步错误判红。
- **备注**：同 PR 把三个侧栏的读取改成 `StatFactsScope.media`（只读本书），见 m5 测量表。
