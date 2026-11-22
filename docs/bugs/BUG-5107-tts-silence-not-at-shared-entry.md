## BUG-5107 · 纯标点句判定只接了部分合成入口：漫画配音 / Galgame 朗读 / 试听仍把「……」「！」送引擎
- **报告**：2026-11-22（来源：PR #4017 / #4001 审查留下的缺口，`docs/reviews/2026-11-21-project-review.md`）
- **真实性**：✅ 真 bug（沿代码路径确认，未在真机复现）。纯标点判定 `ttsTextIsSilent`（`packages/fushi_engine/lib/tts/tts_silence.dart:18`）是在各调用点各写一遍的：朗读调度（`tts_synthesis_scheduler.dart:315` 三目）、整书制作（`tts_render_runner.dart:749`）、补配（`tts_unvoiced_backfill.dart:264`）接了；其余合成入口直接调 `ttsSynthesizeSplittingOnReject`（`tts_reject_split.dart:42`，它本身不判）：
  - 漫画配音 `AppMangaRenderBackend.synthesizeLine`（`fushi/lib/src/media/manga/audio/manga_audio_render_backend.dart:556`）与声音包整批 `prepare`（同文件 `:439`，纯标点片段进 Irodori 批）；
  - Galgame 台词朗读 `synthesizeGalLineTtsWithServices`（`fushi/lib/src/lookup/gal_line_tts_player.dart:418`）；
  - 制作台试听 `_preview`（`fushi/lib/src/media/audiobook/tts/studio/tts_studio_page.dart:1179`）；
  - 声音设置页试听 `_test` 更是直接 `provider.synthesize`（`tts_voice_settings_page.dart:869`），连 #4001 的拒收拆分都没走。

  有的引擎对「……」「！」直接 400（`TtsFailureCode.rejected`），拒收拆分也拆不出可读片段 → 漫画里这句被记成未配音失败（占位 + 账本），Galgame / 试听弹失败提示。另外漫画整句纯标点的气泡即使拿到静音，`synthesizeLine` 的 `silenceremove` 也会把它裁空 → `silent_output` 失败，所以生成端还要把它当停顿出。
- **[x] ① 已修复** — 判定收进唯一的合成入口：`ttsSynthesizeSplittingOnReject` 开头遇纯标点句直接写 `writeTtsSilentLine`（从调度器搬进 `tts_silence.dart`）、不送引擎；朗读调度删掉自己的三目。声音设置页试听改走同一入口。漫画生成端 `MangaAudioRenderer._produce` 遇整句纯标点的气泡出一段 `estimatePlaceholderMs` 长的停顿（`.wav`，非占位、不进账本，与小说整书制作同口径）；声音包整批 `prepare` 跳过纯标点片段。制卡兜底（`mining_tts_fallback.dart`）对纯标点词条报 `models_tts_fallback_nothing_to_read`，不往卡片放静音。整书制作 `_synthesizeChapter` 的分拣抽成纯函数 `sortTtsChapterSentences`（`tts_render_chapter_sort.dart`）。提交：da33c238e1（engine）、7127195ed1（app 侧）。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/tts/tts_reject_split_test.dart`（纯标点句不调引擎、写占位长度静音；已取消照常取消）、`packages/fushi_engine/test/tts/manga_audio/manga_audio_renderer_test.dart`（纯标点气泡出停顿、不进账本、重跑沿用）、`fushi/test/media/manga/audio/manga_audio_render_backend_prepare_test.dart`（纯标点片段不进批）、`fushi/test/media/audiobook/tts/studio/tts_render_chapter_sort_test.dart`（分拣：纯标点进 silent、不解析声音、不算失败）、`fushi/test/creator/mining_tts_fallback_test.dart`（纯标点词条不合成）。
- **备注**：补配 `backfillTtsUnvoiced` 循环里的纯标点跳过（`tts_unvoiced_backfill.dart:264`）仍是内联判断、没有端到端测试（函数依赖整套 app host）；它现在只决定「不解析声音、直接销账」，就算漏判也不会把纯标点句送引擎（统一入口兜住）。真机未验。
