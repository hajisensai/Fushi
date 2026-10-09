## BUG-3105 · 歌词模式竖排不逐字推进、暂停或查词时当前句被纯色块盖住
- **报告**：2026-10-09（用户：群聊截图 `294159bfdb63cee127831a66b6ddae4e`——竖排歌词暂停时当前句是一整块青色竖条、字看不见；竖排播放时不像横排那样按字推进）
- **真实性**：✅ 真 bug。两个现象同一个根因：`fushi/lib/src/media/audiobook/lyrics_mode_html.dart` 的竖排扫过规则写成 `body.ly-sweep.ly-vertical .cue.current .tx`（修前约 406 行）。
  - 它**没有**横排规则的 `:not(.ly-paused)` / `:not(.ly-nosweep)` 门。暂停（`__lyricsSetPlaying(false)` 挂 `ly-paused`）或查词（`ly-nosweep`）时横排规则退场、`background-clip: text` 一起没了，只剩这条竖排规则的 `background-image`——渐变画成实心底，文字颜色与底色同为当前行色，当前句变成一整块色条（截图里的青色竖条；查词截图里只剩「聞いて」三字的查词高亮露出来）。
  - 播放中它的特异性（5 个类）又**低于**横排规则（6 个类：`:not(...)` 里的类计入），于是竖排也吃 `linear-gradient(to right, …)`。竖排一列文字的盒是窄竖条，`to right` 只沿列宽横向过渡，看不出逐字推进。
- **[x] ① 已修复** — 竖排规则改为 `body.ly-sweep.ly-vertical:not(.ly-paused) .cue.current:not(.ly-nosweep) .tx`（`lyrics_mode_html.dart:417`）：与横排同门、多一个 `.ly-vertical` 类特异性更高，播放中走 `to bottom`、暂停 / 查词时整行用纯色。同 PR 加了「逐字跟读渐变」开关（`lyrics_sweep`），关掉时不挂 `ly-sweep`。
- **[x] ② 已加自动化测试** — `fushi/test/reader/audiobook_highlight_style_test.dart`（`BUG-3105` 组）：抽出生成 CSS 里所有给当前行 `.tx` 铺渐变的规则，断言每条都带 `:not(.ly-paused)` 与 `:not(.ly-nosweep)`，且竖排规则类数多于横排规则、方向为 `to bottom`。旧选择器下两条断言都会红。
- **备注**：像素证据用 headless Chrome 渲染生成的歌词页（横排 / 竖排 × 播放中 / 暂停 × 修前 / 修后），见 PR 描述。歌词页不分翻页 / 滚动 / VN 三种正文 view mode（它是独立 WebView），三模式只影响正文当前句高亮，那部分在同 PR 的高亮样式改动里另验。
