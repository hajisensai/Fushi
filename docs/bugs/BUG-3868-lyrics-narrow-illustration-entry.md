## BUG-3868 · lyrics-narrow-illustration-entry
- **报告**：2026-10-28（用户：群反馈，手机歌词模式播到章节扉页没有插画）
- **真实性**：✅ 真 bug。窄屏播放卡头行可用宽度不够时先省小封面（`fushi/lib/src/media/audiobook/lyrics_player/lyrics_player_md3.dart` `_NarrowControlBar._buildHeader` 的 `showCover` 判据），而小封面是窄屏唯一的插图入口；倍速 / 计时 / 重播 / ⋯ 胶囊占满后入口随之消失。另外窄屏插图只换小封面缩略图，没有宽屏封面位那样的弹出。
- **[x] ① 已修复** — 有插图时头行先省章名、留小封面；新增 `LyricsIllustrationPopupCard`：播放走过插图时在标题处弹出插图卡（与宽屏封面位同一套 `LyricsIllustrationController.shown` 逻辑：左右翻页 / 中间看大图 / ✕ 收起），MD3 与 Apple 两套都接；章名（Apple 为书名行）经 `LyricsIllustrationTapTarget` 也能打开插图。
- **[x] ② 已加自动化测试** — `fushi/test/media/audiobook/lyrics_m3e_player_card_round7_test.dart`（393 宽：小封面在、走过插图后弹卡停在播放卡上方、点中间看大图、✕ 收起、章名可打开）。
- **备注**：歌词模式不读「图片暂停」设置（只阅读器正文 WebView 用），本次未改。未在真机复测。
