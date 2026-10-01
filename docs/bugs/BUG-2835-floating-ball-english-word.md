## BUG-2835 · 悬浮球查词取词未适配英语
- **报告**：2026-10-01（用户：悬浮球的分词没有适配英语）
- **真实性**：✅ 真 bug。悬浮球的三条查词入口都把「被点字下标 → 查哪个词」硬编码成日语分词器 `JapaneseLanguage.instance.wordFromIndex`（`fushi/lib/popup_main.dart` `_extractWord`：Android 截屏识字 / 悬浮字幕 → 独立查词窗；`fushi/lib/src/media/audiobook/floating_lyric_lookup_host.dart` `_lookup`：应用内截屏识字 / 拍照查词；`floating_lyric_lookup_routing.dart`：桌面悬浮字幕 → 全局查词窗）。它从被点字起向后做词典最长匹配：英文点 "world" 的 'r' 查的是 "rld…"，匹配不到就退化成单个字母 'r'——截屏识字的字框按行宽等分估计，几乎总落在词中。查词窗原句条（`fushi/lib/src/utils/components/clipboard_lookup_text_panel.dart` `_lookupAt`）同样从被点字起取后缀。
- **[x] ① 已修复** — 新增 `fushi/lib/src/lookup/latin_word_lookup.dart`：拉丁单词字符先回退到词首再交给分词器（与视频字幕点词 `subtitleTranscriptLookupSpan` 同口径），引擎匹配不到整词时用整个单词、匹配到短语时用短语；三条入口改走 `lookupWordAtIndex`，原句条点字回退词首并把锚点下标同步到词首（高亮框整词）。视频字幕的拉丁判据改用同一份 `isLatinWordGrapheme`。
- **[x] ② 已加自动化测试** — `fushi/test/lookup/latin_word_lookup_test.dart`（词中起查 / 无词典用整词 / 短语 / 重音与 NFD / 日文不变 / 混排 / 越界）、`fushi/test/widgets/clipboard_lookup_text_panel_test.dart` 新增「点拉丁词中间从词首起查」。
- **备注**：未在真机截屏识字上复测英文页面。
