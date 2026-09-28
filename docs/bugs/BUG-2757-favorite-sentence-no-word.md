## BUG-2757 · 查词弹窗顶栏收藏句子后收藏夹看不到对应的单词
- **报告**：2026-09-28（用户：「如果点击整个单词的收藏（而不是单个词典的收藏）就会直接收藏句子，却不会显示对应的单词。」）
- **真实性**：✅ 真 bug。查词弹窗顶栏的 ★ 是「收藏当前句」（阅读器
  `fushi/lib/src/pages/implementations/reader_fushi_page.dart` `buildPopupAudioControls` →
  `reader_fushi/chrome.part.dart` `_toggleFavoriteSentence`；视频
  `video_fushi/lookup_favorite.part.dart` `_toggleFavoriteSentenceForVideo`），写入的
  `FavoriteSentence`（`packages/fushi_audio/lib/src/audiobook/favorite_sentence_repository.dart`）
  没有任何「查的是哪个词」的字段，收藏夹只能显示句子。
- **[x] ① 已修复** — commit `870c6b5148c`：`FavoriteSentence` 加可选 `expression` / `reading`（JSON 字段，
  旧条目缺键为 null，不升 schema）；从弹窗顶栏 ★ 收藏时记下顶层查词结果的首个词头（嵌套层不算），
  划选 / 右键菜单收藏没有查词对象不记。收藏夹在句子上方以强调色显示该词，详情显示词与读音；
  带词的收藏句可进批量制卡。
- **[x] ② 已加自动化测试** — `fushi/test/media/audiobook/favorite_sentence_source_test.dart`（字段往返与
  旧条目兼容）、`fushi/test/pages/favorite_words_in_collections_test.dart`（收藏句旁显示对应单词）。
- **备注**：存量收藏句没有记过查词对象，仍只显示句子。真机未复测。
