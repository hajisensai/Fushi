## BUG-5403 · 歌词显示面板开着时切歌置灰状态不刷新
- **报告**：2026-11-24（#4365 合并审查遗留，拍板台 review-merge-1124-leftovers 第 2 条）
- **真实性**：✅ 真 bug。`music_lyrics_page.dart` 打开面板时传 `MusicLyricsExtras.of(_lyrics?.timeline)`——打开那一刻的快照；面板只订阅偏好仓库，切歌后 `_load` 换了 `_lyrics`，面板里翻译 / 罗马音 / 注音的可用性仍是上一首的，关掉重开才对。
- **[x] ① 已修复** — 歌词页持有 `ValueNotifier<MusicLyricsExtras> _lyricsExtras`，`_lyrics` 改成 setter 唯一入口、换歌词时同步刷新（`music_lyrics_page.dart` `set _lyrics`）；面板改收 `ValueListenable<MusicLyricsExtras>`，与偏好仓库一起 `Listenable.merge` 订阅（`music_lyrics_display_sheet.dart`）。`MusicLyricsExtras` 补值相等，同样的可用性不重复通知。
- **[x] ② 已加自动化测试** — `fushi/test/pages/music_lyrics_page_test.dart`「「歌词显示」面板开着时切歌：置灰状态跟着新歌词刷新」：面板开着从带翻译的歌切到纯原文的歌，同一面板里「翻译」开关变成不可点并显示缺失说明。
- **备注**：
