## BUG-4005 · 歌词模式宽屏底栏收起时字幕跳走、看不到当前句
- **报告**：2026-11-03（用户：「收起底部栏的时候字幕会跳的很远导致我看不到当前句子」）
- **真实性**：✅ 真 bug。底栏自动隐藏会改歌词矩形 → WebView resize；歌词文档的 resize 监听只 `__lyricsFitCues()` + 一次性的 `_lyInitialPosition()`（upstream/develop `fushi/lib/src/media/audiobook/lyrics_mode_html.dart:1024`），不重新对准当前句。竖排时列高变化让列数变化，同一 scrollLeft 落到很远的句子。
- **[x] ① 已修复** — resize 后 `_lyReanchorAfterResize()`：跟随中把当前句对回锚点，手动浏览中让滚动时记下的视口中线那句回到中线（`lyrics_mode_html.dart`）。提交见本 PR（`pr/lyrics-bottom-bar`）。
- **[x] ② 已加自动化测试** — `fushi/test/media/audiobook/lyrics_sliding_window_test.dart`「resize re-anchors instead of only re-fitting」。
- **备注**：Windows 调试实例人工看过；Mac WebKit 未复测。
