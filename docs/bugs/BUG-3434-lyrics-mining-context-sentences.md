## BUG-3434 · 歌词模式高级制卡无法前后加句
- **报告**：2026-10-16（用户：应用内反馈 miuMwosYbx，Windows，2.10.0-debug.19353；附录屏）
- **真实性**：✅ 真 bug。录屏：有声书歌词模式点词 → 高级制卡，「前加一句 / 后加一句」点一下即变灰、句数仍为 1。
  根因 `fushi/lib/src/pages/implementations/reader_fushi_page.dart` `onSetSentenceContextToDraft`：只在**正文** WebView
  跑 `fushiSelection.getSurroundingSentences`（按 DOM 选区切句）；歌词模式的查词发生在独立的歌词 WebView
  （`reader_fushi/lyrics.part.dart` `_buildLyricsWebView`），正文没有选区 → 恒返回空 →
  `AdvancedMiningController.adjustContext` 判「句数没增长 = 到边界」禁用按钮。
- **[x] ① 已修复** — 歌词模式分流到 `_setLyricsSentenceContextToDraft`（`reader_fushi/lyrics.part.dart`）：以查词锚点
  `_lookupCue` 在 `_lyricsCueList` 里的位置取相邻 cue 作上下文；切法抽成纯函数
  `cueContextNeighbors`（`fushi/lib/src/media/audiobook/mining_sentence_draft.dart`），视频字幕
  `_setSentenceContextToDraft` 改用同一函数（不另写一份）。提交见 PR。
  复核修正：初版每句音频区间走 `_sentenceAudioRangeFor`，它用的是**查词句**的章节号
  （`reader_fushi/audiobook.part.dart` `_lookupSectionIndex`），相邻句在上一章 / 下一章时经
  `mining_audio_clip.dart` TODO-956 分支被换算进查词句所在章，合并后成「本章开头 → 查词句结尾」整章区间
  （探针实测：next=0-1000、merged=0-3000）；无位置的普通字幕回落全文文本匹配，重复短句取到更早一句（实测 0-700）。
  改为纯函数 `cueContextDraftSentences` → `miningCueAudioRange`：每句取该 cue 自己的起止与音频文件
  （同一套修零长 / 留白 / A/V 偏移），文本与当前句同源（`LyricsCueTextResolver`）。
- **[x] ② 已加自动化测试** — `fushi/test/media/audiobook/mining_sentence_draft_test.dart`（`cueContextNeighbors` 切片 / 封顶 / 越界；`cueContextDraftSentences` 章节交界加句不得跨章 / 整章区间、跨文件退化只合文本、同文短句取相邻 cue）；
  `fushi/test/pages/reader_lyrics_sentence_context_wiring_guard_test.dart`（阅读器歌词模式分流 + 视频共用同一函数的接线守卫）。
- **备注**：未做真机复测（阅读器 WebView + 有声书播放器无头测不了，接线用源码守卫钉住）。
