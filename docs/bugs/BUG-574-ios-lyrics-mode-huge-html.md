## BUG-574 · iOS 歌词模式整本字幕 HTML 导致打不开
- **报告**：2026-07-07（用户：）
- **真实性**：✅ 真 bug。手动进入歌词模式仍会在
  `hibiki/lib/src/pages/implementations/reader_hibiki/lyrics.part.dart:71`
  直接选择 `ctrl.allBookCuesSnapshot`，再交给 `LyricsModeHtml.generate` 生成单个
  HTML 文档并 `loadData`。大书/整本字幕 cue 很多时，iOS WebView 一次加载整本歌词
  HTML 容易超时、白屏或表现为“歌词模式打不开”。上一个 BUG-571 只阻止 fresh open
  自动进入这条路径，手动进入仍会触发。
- **[x] ① 已修复** — 新增 `LyricsCueWindow`，进入歌词模式时只渲染当前 cue 附近最多
  600 句窗口；保留全书 cue 的全局索引 offset，Dart→JS cue 更新时转换为窗口内索引。
  播放推进走出当前窗口时自动重载邻近窗口，不再一次把整本字幕塞进 WebView。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/reader_lyrics_mode_window_guard_static_test.dart`
  守卫 `_loadLyricsPage` 必须经过 `LyricsCueWindow`，并守卫 `_onCueChanged` 必须用
  `_lyricsCueIndexOffset` 转换索引且窗口外触发 `_loadLyricsPage()`。
- **备注**：RED 已确认旧代码直接使用整本 `allBookCuesSnapshot` 且 cue 更新没有窗口
  offset；修复后守卫通过。修复提交：`54488bf7a`。
