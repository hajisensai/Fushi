## BUG-649 · iOS 歌词模式进入时旧页面 onLoadStop 误初始化
- **报告**：2026-07-07（用户：歌词模式依旧有问题）
- **真实性**：✅ 真 bug。根因：`hibiki/lib/src/pages/implementations/reader_hibiki/webview.part.dart:1794`
  在 `_lyricsMode == true` 时无条件调用 `_onChapterLoadComplete(controller)`。进入歌词模式
  会先把 `_lyricsMode` 翻为 true，再 `loadData(LyricsModeHtml)`；如果上一张 EPUB 正文页的
  `onLoadStop` 在这个窗口内晚到，就会被当成歌词页初始化：`_lyricsPageReady` 被置 true、
  lyrics caret/favorites/cue 更新注入到仍是正文的文档里，真正歌词页 load stop 之前状态已乱，
  iOS 上表现为歌词模式仍打不开/白屏/卡住。上一条 BUG-648 只修了 HTML 过大，没有过滤这个
  load-stop 竞态。
- **[x] ① 已修复** — 歌词模式的 `onLoadStop` 先调用 `_isLoadedLyricsDocument()`，通过
  `window.__lyricsSetCue && document.getElementById('lc')` 确认当前 WebView 文档确实是
  `LyricsModeHtml` 后才进入 `_onChapterLoadComplete`；旧正文页或半销毁 WebView 的回调直接
  忽略并记录日志，不再污染歌词 ready 状态。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/reader_lyrics_mode_load_document_guard_static_test.dart`
  先红后绿：守卫歌词模式 `onLoadStop` 必须在 `_onChapterLoadComplete` 前验证歌词文档 sentinel，
  并断言 helper 检查 `window.__lyricsSetCue` 与 `#lc`。
- **备注**：RED 见新测试首次运行失败；修复后该测试通过。仍需用户在真机上点进歌词模式复测原始 UI 路径。
