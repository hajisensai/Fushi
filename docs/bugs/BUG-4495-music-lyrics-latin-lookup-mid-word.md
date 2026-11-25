## BUG-4495 · 音乐歌词点英文单词中间的字母只查到后半截
- **报告**：2026-11-12（用户：应用内反馈 z1vUVtEEED「音乐模块查词没有适配英语，点击某个单词只会出单词的一部分」）
- **真实性**：✅ 真 bug。根因：`fushi/lib/src/pages/implementations/music/music_lyrics_page.dart:190` `musicLyricsLookupTerm` 直接从被点字符 `substring` 到行尾，拉丁字母不回退词首（点 `world` 的 `r` 查 `rld…`）；与视频字幕 / 截屏识字 / 漫画 OCR（BUG-4361）共用的「拉丁单词字符回退到词首」规则（`fushi/lib/src/lookup/latin_word_lookup.dart` `latinWordRangeAt`）不一致。
- **[x] ① 已修复** — 新增 `musicLyricsLookupStart`：被点的是拉丁单词字符时起点回退到 `latinWordRangeAt(...).start`，其余脚本仍从被点字起。`musicLyricsLookupTerm`、源注音区间 `musicLyricsRubySpans` 的坐标起点、制卡句子上下文的 `_lookupCharIndex` 统一用这个起点。副屏查词路由（`routeMusicLyricLookup`）传整行 + 原下标，由副屏侧取词，未改。
- **[x] ② 已加自动化测试** — `fushi/test/media/music/lyrics/music_lyrics_page_logic_test.dart` 新增 2 条：词中 / 词尾 / 词首字母都从词首查、重音字母与数字算词内、日英混排不越过日文、日文仍从被点字起、点空格不动；注音区间随回退后的起点计算。
- **备注**：未做设备肉眼复测（纯函数路径，测试覆盖起点计算）。
