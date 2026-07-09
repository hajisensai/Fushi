## BUG-646 · iOS 重开书籍恢复歌词模式导致内容超时白屏
- **报告**：2026-07-07（用户：）
- **真实性**：✅ 真 bug。根因是 fresh open 时把上个会话持久化的 `lyrics_mode`
  恢复到 `_lyricsMode`（`hibiki/lib/src/pages/implementations/reader_hibiki_page.dart:1497`），
  WebView 创建后会因此跳过正常章节加载，直接 `_loadLyricsPage()`（`hibiki/lib/src/pages/implementations/reader_hibiki/webview.part.dart:1426`）。
  `_loadLyricsPage()` 会把整本/整章字幕生成 `LyricsModeHtml` 并 `loadData`（`hibiki/lib/src/pages/implementations/reader_hibiki/lyrics.part.dart:91`），
  iOS 上重开大字幕书容易触发内容 ready 超时，严重时 WebView 白屏。
- **[x] ① 已修复** — fresh reader open 固定回正文模式：初始化时先 `_lyricsMode = false`，
  只清掉旧的 persisted `lyrics_mode`，不再把它恢复成 UI 模式。用户仍可在当前 reader 会话内手动切歌词模式。
  提交：`774acf3e7`。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/reader_lyrics_mode_reopen_guard_static_test.dart`
  守卫 `_initBookInner` 不得恢复 `savedLyricsMode`，并必须清理旧 `lyrics_mode`。
- **备注**：RED 已确认旧代码缺少 `_lyricsMode = false` 且恢复 `savedLyricsMode`；修复后该守卫通过。
