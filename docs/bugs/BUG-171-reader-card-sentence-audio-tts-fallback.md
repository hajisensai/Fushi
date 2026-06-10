## BUG-171 · 纯文本书籍制卡无句子音频（Lapis SentenceAudio 空）

- **报告**：2026-06-11（用户：`ひびき.apkg` 这个卡组制卡的时候没句子音频，修复一下）
- **真实性**：✅ 真 bug。根因在 `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart:2896`——书籍制卡的句子音频仅当书绑定了有声书音频（`cue != null && audioFiles != null`）时才裁剪生成；纯文本 EPUB（无有声书 / SRT）时 `_lookupCue == null` 且 `_audiobookController == null`（`audioFiles == null`），整个句子音频分支被跳过，`AnkiMiningContext.sasayakiAudioPath` 为 null → `{sasayaki-audio}` 渲染成空 → Lapis `SentenceAudio` 字段留空。**非字段名不匹配，而是纯文本书缺句子音频兜底来源。**
- **[x] ① 已修复** — 提交 `271c5bf08`：纯文本书制卡无真实句子音频源时，复用单词音频已用的 `TtsChannel.instance.ttsToFile`（macOS `say` / Windows SAPI / Android 原生 TTS）为整句合成 OS TTS 句子音频兜底。决策抽成纯函数 `shouldSynthesizeSentenceTtsFallback`（真实句子音频缺失且句子非空才合成，绝不覆盖有声书真实音频）。失败 / Linux / 无日语 voice 返回 null → 字段仍空（优雅降级，与修复前一致）。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/reader_sentence_audio_fallback_test.dart`（纯函数 4 例：有真实音频不合成 / 无音频且句子非空则合成 / 空路径视为缺失 / 空句子不合成）+ `hibiki/test/reader/reader_mining_audio_guard_test.dart` 新增守卫（reader 制卡必须接 `shouldSynthesizeSentenceTtsFallback(` 与 `TtsChannel.instance.ttsToFile(`）。

### 根因（apkg 实证）

解压用户的 apkg（zip → `collection.anki21b` 是 zstd 压缩的新版 sqlite，解压后查 `notetypes` / `fields` / `notes`）：

- note type = **Lapis**（22 字段），句子音频字段 = **`SentenceAudio`**（ord 9），其字段映射占位符 = `{sasayaki-audio}`（`packages/hibiki_anki/lib/src/lapis_note_type.dart:70`）。
- 两条真实 note（deck 名 "ひびき"，`IsWordAndSentenceCard=x`）均：`ExpressionAudio`=`[sound:hibiki_audio_*.mp3]`（单词音频）✅、`Sentence`（例句）✅、`Picture`=`<img src="hibiki_cover_*.jpg">`（**书籍封面**，确认书籍阅读器制卡而非视频）✅，但 **`SentenceAudio` 长度 0（空）** ❌。
- 字段映射与 backend 渲染均正确：`ankiconnect_repository.dart:368-396` 当 `context.sasayakiAudioPath != null` 时会 `storeMediaFile` 并渲染成 `[sound:...]`；`anki_models.dart:330` `{sasayaki-audio}` → `context.sasayakiAudioPath ?? ''`。即字段名 `SentenceAudio` 与 Hibiki 映射完全匹配，空值是因为 `sasayakiAudioPath` 本身为 null。

对比：video 制卡（`video_hibiki_page.dart:1477`）必有音轨故句子音频正常；有声书制卡有 cue 故正常（见 BUG-149 / 144）。唯独纯文本书无音频源时句子音频无兜底。

### 修复

- 新增纯函数 `hibiki/lib/src/pages/implementations/reader_sentence_audio_fallback.dart` 的 `shouldSynthesizeSentenceTtsFallback({realSentenceAudioPath, sentence})`。
- `reader_hibiki_page.dart onMineFromPopup` 在真实句子音频裁剪块之后接入：判定为 true 时建独立临时目录（复用 `sasayakiTempDir` 与末尾 `finally` 清理）用 `ttsToFile(sentence, ...)` 合成，结果赋 `sasayakiAudioPath`。

### 验证

- `flutter test test/pages/reader_sentence_audio_fallback_test.dart test/reader/reader_mining_audio_guard_test.dart`（8 绿）
- `flutter test test/anki`（53 绿）+ `packages/hibiki_anki` `flutter test`（50 绿）
- `flutter analyze`（改动 4 文件 0 issue）+ `dart format`。

### 备注

- **TTS 音质不可靠**（诚实声明）：`desktop_tts.dart` 注释明确——发音质量完全取决于 OS 已装日语语音（macOS Kyoko / Otoya，Windows Haruka，Android 系统 TTS）；只有英语语音时整句日语会读错；Linux 无可靠日语引擎 → 仍返回 null（字段空）。本修复把"诚实的空字段"换成"尽力而为的合成音"，非真人 / 有声书音质。
- 未加全局开关（YAGNI）；只在真实句子音频不可用时兜底，对有有声书的书零行为变化。
- **真机 / 桌面待验**：真实 Anki 制卡（AnkiConnect / AnkiDroid 真后端）+ OS TTS 真合成需真机或桌面用纯文本书制一张卡，验 Anki `SentenceAudio` 有 TTS 句子音；本轮到代码路径 + 纯函数 + 源码守卫层。
