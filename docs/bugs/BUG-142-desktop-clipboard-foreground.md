## BUG-142 · 桌面剪贴板自动查词在未开始真实搜索前抢前台
- **报告**：2026-06-08（用户：开启自动搜索剪贴板时会在任何时候把窗口拉到前台）
- **真实性**：✅ 真 bug。根因：`hibiki/lib/src/sync/desktop_lookup_service.dart:110`
  / `:117` 在剪贴板命中或全局热键读到文本后立刻 `submitText()` 并 `_bringToFront()`；
  但真正能把词送进查词页并开始搜索的是
  `hibiki/lib/src/pages/implementations/home_dictionary_page.dart:84` 的外部查询消费路径。
  旧实现把“发现剪贴板文本”误当成“搜索页已能真实搜索”，导致未消费/未开始查询时也抢前台。
- **[x] ① 已修复** — `DesktopLookupService` 只排队 `pendingText`，不在剪贴板/热键回调内拉前台；
  `HomeDictionaryPage._consumeExternalQuery()` 实际消费外部查询并准备 `_search(...)` 前再调用
  `bringPendingLookupToFront()`。
- **[x] ② 已加自动化测试** — `hibiki/test/sync/desktop_lookup_service_test.dart`
  新增 `clipboard hit queues lookup but waits for UI before foreground`，断言剪贴板变化只排队查词请求，
  不直接调用 `window_manager.show/focus`。
- **备注**：本次修的是桌面剪贴板查词路径；Android 悬浮词典服务路径未改。
