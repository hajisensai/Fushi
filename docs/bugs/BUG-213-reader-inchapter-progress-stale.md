## BUG-213 · 阅读器章内滚动进度不更新
- **报告**：2026-06-12（用户：章内滚动进度不会动，只有到下一章了进度才会更新一次）
- **真实性**：✅ 真 bug。章内进度 UI 字段 `_progressCurrentChars/_progressTotalChars`
  唯一写入点是 `_refreshProgress()`
  （`hibiki/lib/src/pages/implementations/reader_hibiki_page.dart:4005`，:4047-4058 写字段）。
  `_refreshProgress` 仅 3 处触发：① 章节恢复完成 `_onRestoreComplete()`（:2754）；
  ② 每 10 秒轮询 `_startProgressPoll()`（:2758-2764，`Timer.periodic(10s)`）；
  ③ 分页模式翻页成功后 `_paginate()`（:5219）。
  **缺口**：章内**原生滚动**（连续模式 `window` 滚动、分页模式触摸/trackpad/键盘箭头
  落在 `document.body`/`window` 的原生滚动）没有任何进度回传通道 ——
  JS 侧 `registerSnapScroll`
  （`hibiki/lib/src/reader/reader_pagination_scripts.dart:915-938`）只做 viewport
  lock / 列对齐，从不 `callHandler` 把进度回传 Dart；连续模式 shell
  （`_continuousShellScript` :1386）用 `window.scrollTo` 原生滚动，根本不调
  `registerSnapScroll`。→ 章内滚动进度条不动，要等 10s 轮询或翻到下一章才更新一次。
  与 BUG-210(`9461c20f3` 重排容差)/BUG-211(`a8ff069a7` 高水位计字) 无关，是独立既有问题。
- **[x] ① 已修复** — `5ef9e28a9`：在两模式共享的 setup 脚本
  `_buildReaderSetupScript`（:2149 附近 `hoshiProgressDetails` 同段）注册 `window` +
  `document` scroll 监听，经 rAF + 200ms debounce 后
  `callHandler('onReaderScroll')`；Dart 侧新增 `onReaderScroll` handler →
  `_handleReaderScroll()` 在 `_readerContentReady && !_restoreInFlight && !_lyricsMode`
  时调 `_refreshProgress()`（复用既有重算路径，high-water-mark 计字不重复累计、
  `_debouncedSavePosition` 已有 500ms 去抖，零字数路径改动）。恢复期/歌词模式由
  `readerScrollProgressRefreshAllowed()` 纯函数门控，程序化恢复滚动不误触发。
- **[x] ② 已加自动化测试** — `test/reader/reader_inchapter_progress_scroll_test.dart`：
  纯函数 `readerScrollProgressRefreshAllowed()` 门控真值表（恢复期/歌词/未就绪不触发，
  正常滚动触发）+ JS 通道源码守卫（断言 setup 脚本含 `onReaderScroll` scroll 回传 +
  rAF/debounce，断言 Dart 注册了 `onReaderScroll` handler 且走 `_refreshProgress`）。
- **备注**：needsDevice — 真机/模拟器滚动验证进度条实时跟随、不抖动、恢复期不误触发
  待用户复测（reader/WebView 类，CLAUDE.md 验证纪律）。撞号：`bug.dart new` 取本地最高号
  +1=212，但 212 已被并发分支 `worktree-agent-aecc045626aa9c31b`
  （theme-custom-palette）占用，遍历所有 worktree 分支取并集后改用 213。
