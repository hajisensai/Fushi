## BUG-785 · 重新进入书籍不再是歌词模式（歌词模式跨会话不恢复）
- **报告**：2026-07-13（用户：重新进入书籍又不是歌词模式了）。
- **真实性**：✅ **既有有意行为，按用户请求改为可恢复**。`reader_hibiki_page.dart` `_initBookInner` fresh open 时 `_lyricsMode=false` 并 `setLyricsMode(false)` **抹除**持久化的 `lyrics_mode` 偏好。注释原因：直接按 persisted lyrics_mode 让 WebView 整页加载歌词 HTML、跳过 EPUB 正文，iOS 大字幕书会内容超时甚至白屏。故此前每次开书重置。
- **[x] ① 已修复** — `f65d94189`。**安全延迟恢复**：① `_initBookInner` 不再抹除偏好，改记一次性意图 `_pendingLyricsRestore = ReaderHibikiSource.instance.lyricsMode`（仍 `_lyricsMode=false` 起步，fresh open 绝不直接整页加载歌词 HTML → 保留 iOS 白屏防护）；② `_onChapterLoadComplete` EPUB 正文首次就绪且有声书已挂载后（正文已加载，切歌词等价手动切、已知安全），若 `_pendingLyricsRestore && _audiobookController != null && !_lyricsMode` 则 `_toggleLyricsMode()` 进入，随即清零意图防每章重触发；无有声书则不恢复。退书不抹偏好故下次恢复。
- **[x] ② 已加自动化测试** — `test/pages/reader_lyrics_mode_reopen_guard_static_test.dart` 由「fresh open 绝不恢复」改写为「起步仍正文 + 捕获意图代替抹除」；`test/pages/reader_lyrics_input_bridge_guard_static_test.dart` 新增用例（`_onChapterLoadComplete` 的 `if (_pendingLyricsRestore)` 触发含 `_audiobookController != null` + `_toggleLyricsMode()` + 一次性清零）。
- **备注**：reader/init 时序/iOS 白屏防护类。真机复测（歌词模式退书→重开同书自动回歌词且不白屏；手动退歌词后重开为正文；无有声书的书不误进；iOS 大字幕书不白屏）待用户后补。原为 PR#76 的 BUG-769/782，因并发撞号重编号本号。
