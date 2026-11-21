## BUG-4710 · SRS 浏览健康条把视频片段卡都算成「缺单词音频」
- **报告**：2026-11-16（用户应用内反馈 YTfy39ieEH，Windows 3.3.0+24434：卡片音频能正常播放，但卡片概览显示所有卡都缺单词音频）
- **真实性**：✅ 真 bug。健康条与「问题卡」快捷视图的缺音频条件是 `-has:audio note:"<Fushi 卡片类型>"`（`fushi/lib/src/pages/implementations/srs/srs_browse_saved_views.dart:91`、`:108`），`has:audio` 在搜索内核里只认字段原文含 `[sound:`（`native/fushi_fsrs/src/search.rs:869-873`）。而 SRS 制卡与 Anki 共用 `AnkiNoteComposer.renderMediaPayload`（`fushi/lib/src/srs/srs_mining.dart:3-4`），WebM 内嵌片段制卡（BUG-3442）把单词音频写成重播按钮 + `<audio class="fushi-word-audio" src>`、句子音频写成 `<audio class="fushi-inline-audio">`（`packages/fushi_anki/lib/src/anki_note_composer.dart:974-982`、`:191-212`），整条笔记一个 `[sound:` 都没有；卡面（`srsAudioSources`，`fushi/lib/src/srs/srs_fushi_card_fields.dart:181`）和补全单词音频（`srsWordAudioFieldIsEmpty`，`fushi/lib/src/srs/srs_word_audio_backfill.dart:85`）都把 `<audio src>` 当音频，只有搜索内核不认，于是这类卡能播却全被数成缺音频。
- **[x] ① 已修复** — `has:audio` 改为字段原文含 `[sound:` **或** `<audio` 标签（标签名不区分大小写，`audio` 后须是空白 / `>` / `/`，`<audiox>` 不算）；`has_img_tag` 泛化为 `has_tag(html, name)`，`has:image` 行为不变。Dart 侧 `SrsSearchHasMedia` 注释与 spec 2026-11-04 §2.3 同步。
- **[x] ② 已加自动化测试** — `native/fushi_fsrs/src/search.rs` `retrievability_and_media_terms`：制卡同形的 `<AUDIO class="fushi-word-audio" src>`、跨行属性的 `<audio\nsrc=…>` 命中 `has:audio`，`<audiox>` 不命中，`<audio>` 不误中 `has:image`（修复前红：`left: [0, 0, 0] right: [1, 0, 1]`）。
- **备注**：
  - 未改：`has:audio` 仍是「任一字段」，不是只看单词音频字段——句子音频带 `[sound:]`、单词音频真空的 Fushi 卡仍会漏报「缺单词音频」。要按字段判断需要新增字段级媒体谓词（spec §2.3 写明「内核不另设词」）或让健康条拼一条字段正则查询（会以正则积木显示给用户），属于取舍，未在本次处理。
  - 未在真机上复测健康条计数。
