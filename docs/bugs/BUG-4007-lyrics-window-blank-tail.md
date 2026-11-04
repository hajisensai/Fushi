## BUG-4007 · 歌词模式自动播放一段后后面的文字空白、拨过去整页刷新
- **报告**：2026-11-03（用户：「在自动播放到一定程度的时候，后面的文字是空白，拨过去以后会重新刷新加载……不可接受有空白的情况」）
- **真实性**：✅ 真 bug。歌词文档只装当前句前后各 300 句的窗口（`kLyricsModeMaxInitialCues = 600`，`LyricsCueWindow.select`），播到窗口尾部后面就没有句子；播放越过窗口边界才在 `_syncLyricsOverlayCue` 里整页 `_loadLyricsPage()` 重载（upstream/develop `fushi/lib/src/pages/implementations/reader_fushi/lyrics.part.dart:961`）。
- **[x] ① 已修复** — 滑动窗口原地拼接：`_slideLyricsWindow`（`reader_fushi/lyrics.part.dart`）在播放离窗口边缘不足 `kLyricsWindowEdgeMargin` 句、或 JS 报窗口首 / 末句进入视口外扩一屏（`onLyricsEdge`）时，用 `LyricsModeHtml.cueRowsHtml` 生成一段 `kLyricsWindowChunk` 句交给 JS `__lyricsSpliceCues` 原地插入，并卸掉离当前句足够远的另一端（窗口常驻上限不变）；拼接按锚点句补偿滚动、关掉浏览器滚动锚定。只有拖到窗口外很远才整页重载。提交见本 PR（`pr/lyrics-bottom-bar`）。
- **[x] ② 已加自动化测试** — `fushi/test/media/audiobook/lyrics_sliding_window_test.dart`（增量行不带 current/near、首尾标记、拼接 / 边缘请求 API、播放近边缘先滑动后重载的源码守卫）。
- **备注**：拼接 JS 只有生成器 / 源码层测试，DOM 行为在 Windows 调试实例上人工看过；三种 view mode 不适用（歌词覆盖层是独立文档）。Mac WebKit 未复测。
