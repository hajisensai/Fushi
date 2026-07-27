## BUG-1171 · 漫画阅读器销毁后仍写页码通知器并挂 10 秒
- **报告**：2026-07-27（用户：PR#474 只读审查）
- **真实性**：✅ 真 bug，两处。
  1. `hibiki/lib/src/media/manga/reader/manga_hibiki_page.dart:1534`（修复前）的 `_recordProgress` 写 `_pageNotifier`、并在 `:1537` 新建 600ms Timer；它的调用点 `_markWindowReady:2130` / `_applyMangaTurnStep:988` / `_onMangaScroll:1186` / `_jumpToPageAnchor:1054` **全在若干 await 之后**且无 mounted 复检（`:2095` 的 mounted 检查在 3 个 await 之前）→ `ValueNotifier used after being disposed`，并留下 dispose 已 cancel 之后才新建的泄漏定时器。与 BUG-1154 同源、同类、未修。
  2. `dispose`（`:537-550`）不收尾 `_windowLoadCompleter`：页面在加载中被销毁时 `:941` 的 `ready.future.timeout(10s)` 会**挂满 10 秒**后 `:946` `rethrow`，而调用方 `:2071` 是 `unawaited(...)` ⇒ 未捕获异步异常。
- **[x] ① 已修复** — ①`_recordProgress` 首行 `if (!mounted) return;` 收成唯一闸门（它是 `_pageNotifier` 与 debounce Timer 的唯一写入点，逐个调用点加复检既啰嗦又会再漏）。②新增 `MangaWindowLoadOutcome{ready, abandoned}`（`manga_window_load_gate.dart`），`dispose` 调 `_windowGate.abandon()` 把在飞加载以 `abandoned` 立刻收尾；`_loadInitialWindow` 拿到 `abandoned` 直接 return，既不当失败上抛、也不再碰 State。
- **[x] ② 已加自动化测试** — `hibiki/test/media/manga/manga_window_load_gate_test.dart`「销毁时在飞的加载立刻以 abandoned 收尾」：断言 `abandon()` 后 `ticket.outcome` 立即完成为 `abandoned`、之后迟到的就绪回调不得改写结论、`ticketFor` 返回 null。
- **备注**：PR#474 新增面审查产物。`_recordProgress` 的 mounted 闸门同时消掉了 4 个调用点的同类漏点。
