## BUG-1815 · 歌词文档守卫静态测试未跟随 finalizer 重构
- **报告**：2026-08-24（Apple 全量回归门）
- **真实性**：✅ 真测试门 bug。生产加载链已重构为 `onLoadStop` 调用 `_finalizeLyricsDocumentIfReady`（`fushi/lib/src/pages/implementations/reader_fushi/webview.part.dart:2495-2516`），finalizer 内部仍严格先 `_isLoadedLyricsDocument`、再 `_onChapterLoadComplete`（同文件 `2597-2612`）；旧静态测试只在 `onLoadStop` 函数体内搜索两个直接调用，因此守卫真实存在且顺序正确时仍报 `-1`。
- **[x] ① 已根因修复** — 测试先断言歌词分支调用当前 finalizer，再提取 finalizer 函数体，断言 DOM sentinel guard 早于 chapter complete；不放松产品安全不变量，只更新调用图认知。提交 `2b21b9513`。
- **[x] ② 已加自动化测试** — `fushi/test/pages/reader_lyrics_mode_load_document_guard_static_test.dart:21-50` 现在覆盖 `onLoadStop → finalizer → guard → complete` 全链；删掉 finalizer 调用、删掉 guard/complete 任一调用或交换两者顺序都会红。定向运行修复前稳定 `Expected non-negative, Actual -1`，修复后通过。
- **备注**：同一测试继续检查 `window.__lyricsSetCue` 与 `document.getElementById('lc')` 两个真实歌词 DOM sentinel。
