## BUG-3531 · lyrics-mode-drops-dashes
- **报告**：2026-10-18（用户：歌词模式好像会吞掉很多符号引号破折号等）
- **真实性**：✅ 真 bug。歌词行按匹配区间（归一化坐标，标点已剥）从章纯文本截取，区间两端的标点靠 `fushi/lib/src/media/audiobook/lyrics_cue_text.dart` 的 `_extendOpening` / `_extendClosing` 按白名单 `_kOpening` / `_kClosing` 补回；白名单没有破折号（`—` `―`）、`・`、`〝〟` 等，补到第一个不认识的字符就停——句末 `――」` 连破折号带闭引号一起丢，行首 `――「` 的破折号丢，只剩标点的缝隙两边都不认领。
- **[x] ① 已修复** — 白名单换成结构化切分 `_gapSplit`：两个有读音的字之间的无读音缝隙按「段落边界（`blockEnds`）→ 第一个空白 → 第一个开括号 → 整段归前一行」切成前后两份，前后两条 cue 用同一切点，符号不丢也不重复；`skippedTextBetween` 走同一切点。
- **[x] ② 已加自动化测试** — `fushi/test/media/audiobook/lyrics_cue_text_test.dart`（破折号 + 闭引号、行首破折号、`〝〟` / `・` / `—`、相邻 cue 分缝不丢不重）；顺带修正测试辅助 `line()` 直接归一化 HTML 时 `<br/>` 的「br」被当成有读音的字导致下标偏移。
- **备注**：纯显示改动，不改匹配区间与已落库的 cue。
