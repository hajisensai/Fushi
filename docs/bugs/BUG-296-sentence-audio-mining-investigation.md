## BUG-296 · ひびき/Lapis 卡组制卡缺句子音频根因调查（TODO-390）

- **报告**：2026-06-15（用户：「ひびき这个 anki 卡组，制卡出来没有句子音频」）。与 BUG-172（TODO-104a，有声书线）/ BUG-188（TODO-104b，视频线）同一类用户诉求的再次提报；那两条已在代码层修复但**从未真机/真 Anki 验证**（两条备注均明写「真机听声待验」）。
- **真实性**：✅ 部分真 bug（视频线存在静默丢失盲区，已修）+ 大部分为「真机层 / 用户配置」需用户配合复测。沿真实代码路径已**穷尽**核查整条句子音频链路，结论如下。

### 句子音频字段定义 + Lapis note type 字段 + 制卡映射链（file:line）

1. **创建器字段**：`hibiki/lib/src/creator/fields/audio_sentence_field.dart:7`（`AudioSentenceField extends BaseAudioField`，label `Sentence Audio`，key `audio_sentence`）。这是创建器 UI 字段（手填搜索词/录音/选音频），**不是**制卡时写句子音频的路径。
2. **真正写句子音频的 handlebar**：`{sasayaki-audio}` → `packages/hibiki_anki/lib/src/anki_models.dart:366`（`_handlebarToValue` 取 `context.sasayakiAudioPath`）。渲染器 `AnkiHandlebarRenderer.render`（`:308`）用正则 `\{[^}]*\}` 替换，单字段值 `{sasayaki-audio}` 能正确命中。
3. **Lapis note type 字段定义**：`packages/hibiki_anki/lib/src/lapis_note_type.dart:34` 含官方字段 `SentenceAudio`（Lapis 1.7.0 verbatim）。
4. **默认字段映射**：`lapis_note_type.dart:70` `'SentenceAudio': '{sasayaki-audio}'`、`:67 'Sentence': '{sentence}'`。
5. **映射应用**：`lapis_preset.dart:18 applyDefaults` / `anki_view_model.dart:92,193`（选卡组 / 一键创建时写持久化 `fieldMappings`）。
6. **句子音频填充链**（构造 `AnkiMiningContext.sasayakiAudioPath`）只有两处：
   - reader：`reader_hibiki_page.dart:3507`（`if (audioFiles != null)`，BUG-172 放宽，按句子 range 抽段 → `:3519 extractAudioSegment`）。失败可见性已存在：`:3538`（`requestedSentenceAudioClip && sasayakiAudioPath == null` → toast + log）。
   - video：`video_hibiki_page.dart:2802`（`hasRange && videoPath != null` → `extractAudioSegmentViaFfmpeg`）。
7. **两后端媒体上传 + `[sound:]` 渲染**：AnkiConnect `ankiconnect_repository.dart:449,477`（`[sound:$ref]`）、AnkiDroid `anki_repository.dart:487 _addSasayakiAudio`（`[sound:$raw]`）。均正确。
8. **UI 可配置**：`anki_settings_page.dart:276 _buildFieldMappings` 列出每个字段（含 SentenceAudio），未映射显示 `anki_field_not_mapped`；`{sasayaki-audio}` 在 `AnkiHandlebarOptions.coreOptions`（`anki_models.dart:439`）可选。

### 根因判定（四选）

- **(a) 缺字段** ❌：Lapis note type 明确含 `SentenceAudio`。
- **(b) 映射断** ❌（标准 Lapis/ひびき 卡组）：`defaultFieldMappings` 含 `SentenceAudio`→`{sasayaki-audio}`，一键创建 / 选卡组时写入。**但**：若用户卡组名不含 `lapis` 且字段集与 Lapis 不完全一致（`LapisPreset.matches` 第二条要求同时含 `Expression`+`MainDefinition`+`Sentence`），或句子音频字段名不是精确 `SentenceAudio`，则 `applyDefaults` 不会自动映射该字段——属用户卡组与预设不符，UI 可自查自填，非代码缺陷。
- **(c) 场景无音源** ✅（最可能的用户感知）：纯文本书 / 纯查词页 / 剪贴板查词制卡本无音源，句子音频为空是正确行为（BUG-172 已澄清「纯文本书无声正确，绝不 TTS 假音」）。
- **(d) 媒体没附 / 抽段静默失败** ✅（视频线真 bug）：**video `_mineVideoCard` 在「本应有句子音频」却抽段失败时完全静默丢弃**——`extractAudioSegmentViaFfmpeg` 真机返回 null（ffmpeg 不可用 / 当前音轨不可解码 / 交错容器读取失败）时，`audioPath` 静默置 null，卡片 `{sasayaki-audio}` 渲染空，用户只看到「制卡成功」却没句子音频，**无任何提示、无任何日志**，无从诊断。reader 线早有此可见性（`:3538`），video 线没有——两路不对称。这正是用户反复报「ひびき 卡组没句子音频」却定位不到的盲区。

### [x] ① 已修复（视频线静默丢失盲区，根因方向 = 失败可见性对称）

- `hibiki/lib/src/pages/implementations/video_hibiki_page.dart` `_mineVideoCard`：`extractAudioSegmentViaFfmpeg` 后，当 `hasRange`（本应有句子音频）但 `audioPath == null`（抽段失败）→ `debugPrint` 一行可追踪日志（含区间端点 + audioStreamIndex）+ `_showOsd(card_export_failed_detail(reason: 'sentence audio export failed'))` 提示用户，**不打断成功制卡**（封面/文本仍正常落卡）。与 reader BUG-172 的失败可见性对称，消除「video 句子音频静默丢失」这一整类盲区。复用现有 i18n key（`card_export_failed_detail`），未新增 17 文件 key。
- 这是根因方向修复而非补丁：错误不是「缺一个音源」，而是「**句子音频本应有却失败时被静默吞掉**」——把无法诊断的静默丢弃变成用户可见 + 日志可追踪，让真机层失败可定位。

### [x] ② 已加自动化测试

- `hibiki/test/pages/video_mining_context_guard_test.dart`：新增源码守卫 `_mineVideoCard surfaces a silent sentence-audio clip failure (BUG-296)`（断言 `_mineVideoCard` 含 `if (audioPath == null) {` + `sentence-audio clip failed` 日志 + `card_export_failed_detail` 提示）。

### 残留（需用户配合真机 / 真 Anki 复测，host 不可验）

- **host 无 ffmpeg / libmpv / 真 Anki**，BUG-172/188 的真实抽段裁剪 + 媒体上传从未真机验证。请用户明确**在哪个场景制卡**并复测：
  1. **有声书阅读**查落在 cue 空隙的词制卡（BUG-172 路径）→ 验 Anki `SentenceAudio` 拿到真实旁白段。
  2. **视频字幕**查词制卡（BUG-188 路径）→ 现在若抽段失败会看到 OSD 提示「sentence audio export failed」，据此判断是 ffmpeg 失败（真 bug，需查捆绑 ffmpeg）还是无音源（正确）。
  3. **纯文本书 / 纯查词页**制卡 → 句子音频空是正确行为（无音源），非 bug。
  4. 检查 Anki 设置页 SentenceAudio 字段是否映射为 `{sasayaki-audio}`（未映射 = 用户卡组与预设不符，自行设置）。
