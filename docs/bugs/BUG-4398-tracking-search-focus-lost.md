## BUG-4398 · Tracking page search box lost focus when the list turned empty or back
- **报告**：2026-11-11（T2 hands-on test G1: typing `Ajx9q` kept only `Ajx`）
- **真实性**：✅ 真 bug. `fushi/lib/src/media/tracking/page/tracking_page.dart` built the empty state with `_list` (an unkeyed `ListView.builder`) and rows with `_lazyList` (`ValueKey('tracking-page-list')`): switching between them replaced the list, so the filter bar (a list header) got a new `EditableText` and focus node and the entrance animation replayed.
- **[x] ① 已修复** — `_list` is now `_lazyList` (one keyed list for rows and empty states); the filter bar is keyed too (T2 F5 commit).
- **[x] ② 已加自动化测试** — `fushi/test/media/tracking/tracking_page_f5_test.dart` ("G1: the search box keeps its focus …").
- **备注**：—
