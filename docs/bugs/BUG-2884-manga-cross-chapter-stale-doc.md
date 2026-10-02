## BUG-2884 · 漫画跨章翻页后正文仍是旧章
- **报告**：2026-10-02（用户：「漫画翻页跨章的时候不会正确进入下一章，只有第一页更新了」）
- **真实性**：✅ 真 bug（沿代码路径确认；真机复现用 itest 本机内存不足被系统停掉，未跑完）。
  - 主因：首次打开时窗口文档由 `onWebViewCreated → _loadInitialWindow()` 装载；换章（`_onReachedChapterEdge → _switchToChapter → _openShelfChapter → _presentPayload`）期间 `_payload` 一直非空、WebView 不卸载，`onWebViewCreated` 不会再来，而 `_presentPayload` 只 `setState` 换 `_payload/_spreads/_currentSpread`、从不重装窗口文档——屏上留着旧章文档，只有页码 / OCR 层 / 进度按新章走（`fushi/lib/src/media/manga/reader/manga_fushi_page.dart` `_presentPayload`，修复后 :1939）。
  - 次因：`_loadInitialWindow` 遇到在飞加载直接 `return`（旧 `|| _navigating) return;`），后到的重装请求被丢弃，同样会停在旧文档（:2677）。
  - 次因：已下载章页名各章同形（`images/page-000001.*`，`manga_download_service.dart` `_pageStem`），拦截 URL 跨章完全相同且响应带 `max-age=3600`（:2461），重装后 WebView 可复用旧章同名页图。
- **[x] ① 已修复** — `_presentPayload` 在 WebView 已存在时 `await _loadInitialWindow()`（直读章提前 return 之前，换章落末页的 translate 在新文档上执行）；`_loadInitialWindow` 改为等在飞加载收尾后按当前状态重装、有排队重装时不提前 drain 翻页队列；页图 URL 带页会话代次 `?v=<generation>`（拦截器只认 path）。
- **[x] ② 已加自动化测试** — 源码守卫 `fushi/test/media/manga/manga_chapter_switch_reload_guard_test.dart`；URL 代次纯函数用例 `fushi/test/pages/manga_fushi_page_pure_test.dart`；真 WebView 端到端 `fushi/integration_test/manga_cross_chapter_itest.dart`（两章已下载、页图尺寸区分章，读 DOM 可见页 `naturalWidth` / 文档页数）。
- **备注**：真机 itest 本轮因本机内存不足被系统停掉，未取得运行证据；合并前需在 Windows 离屏 runner 跑一次 `fushi/tool/run_windows_itest.ps1 -Target integration_test\manga_cross_chapter_itest.dart`。
