## BUG-172 · 有声书制卡词落 cue 空隙时句子音频静默为空（Lapis SentenceAudio 空）

- **报告**：2026-06-11（用户：`ひびき.apkg` 这个卡组制卡的时候没句子音频）。TODO-104 用户补充原话：「是有声书和视频制卡没句子声音」。本条只覆盖**有声书线（104a）**；视频线（104b）另行处理。
- **真实性**：✅ 真 bug。**根因在 `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart:2904` 的门控**（撤回前为 `if (cue != null && audioFiles != null)`）。
  - `_lookupCue`（`reader_hibiki_page.dart:3630`）由 `_findCueForOffset`（`:2776`）严格要求“被查词的 normalized offset 正好落在某 cue 的 `[normCharStart, normCharEnd)` 内”。
  - 有声书 cue 对齐天然有空隙（标题 / 图注 / 对齐失败 / 章首尾）：当词落在“有正文但无 cue 覆盖”处，`_findCueForOffset` 返回 null → `_lookupCue == null` → 门控的 `cue != null` 不过 → **整段句子音频分支被静默跳过**，`AnkiMiningContext.sasayakiAudioPath` 为 null → `{sasayaki-audio}` / `SentenceAudio` 渲染成空，**没有任何报错或提示**。
  - 这是“安静降级”陷阱：音频本来就在（`audioFiles != null`），只是用“按词 offset 找 cue”这一条死路堵住了，而句子本身的归一化 range（`_cachedSentenceRange`，来自 WebView 选区，与 cue 无关）一直可用却没被拿来定位覆盖该句的 cue 区间。
  - BUG-149 / BUG-144 只修了“找到 cue 后范围对不对”，没修“根本没找到 cue”。
- **定性更正（原 TTS 修法已被撤回）**：本条曾被错误定性为“**纯文本书**无音频源缺兜底”，并用 OS TTS 合成整句音频兜底（develop `271c5bf08`）。该方向被 PM 撤回（develop `554d31afb` `revert(anki): drop plain-text book TTS sentence-audio fallback (TODO-104)`），因为用户真实诉求是**有声书制卡缺真实旁白音频段**，不是要 TTS 假音；纯文本书本就没有音频源，无声是正确行为。**本次修复绝不使用任何 TTS 兜底。**
- **[x] ① 已修复** — 提交 `198491a78`：把句子音频解析从“词恰好落在某 cue 内”放宽为“按句子归一化 range 找覆盖该句的 cue 区间”，复用现有 ffmpeg 抽段，不新建管线、不 TTS。
  - `reader_hibiki_page.dart:2904`：门控由 `if (cue != null && audioFiles != null)` 放宽为 `if (audioFiles != null)`；clip 改可空 + null 检查。
  - `mining_audio_clip.dart`：`miningSentenceAudioRange` 的 `cue` 参数改可空、返回类型改可空；`_rangeFromSentencePosition` 在 `cue == null` 时跳过 cue-fragment 的 section 校验，直接信任调用方传入的 `sectionIndex`（来自 `_lookupSectionIndex` = 当前章 / 歌词 fragment section，对选区是权威的），用 `CollectionAudioMatcher.findPlaybackRange(cues, sectionIndex, normCharOffset, normCharLength)` 做句子 range 与 cue 的重叠匹配。`cue == null` 时不落入 cue 相对的 `_expandAroundCue` / `_cueRange`（它们需要 cue 锚点）。
  - `_sentenceAudioMiningCues` 参数改可空，最后 fallback 仅 `cue != null` 才返回 `[cue]`，否则返回空列表（无 cues 即无音频可裁，`miningSentenceAudioRange` 自然返回 null，门控跳过——保持诚实）。
  - 这是根因修复而非补丁：错误的不是“缺一个兜底来源”，而是“**用错了定位信号**”——句子音频本应由句子 range 定位，却被绑死在“词必须落进 cue”这一更窄的条件上。修复让句子 range 这个独立、本就可用的信号承担定位职责，消除了“cue 找到 / 没找到”这个特殊情况分支。
  - **失败可见性**：当 `audioFiles != null` 但既无 cue 也无法由句子 range 解析出 cue 区间时，`debugPrint` 记录一行（lookupCue=null + sentenceRange 是否存在），把原先完全静默的丢弃变为可追踪。未改 toast / i18n（避免改动共享 toast 引入回归，且新增 i18n key 涉及 17 文件超出范围）。
- **[x] ② 已加自动化测试** — 提交 `198491a78`：
  - `hibiki/test/media/audiobook/mining_audio_clip_test.dart`：新增 `recovers sentence audio for a gap word with no lookup cue`（cue==null + 句子 range 命中 → 拿到完整非空 range；撤兜底实测转红）+ `returns null when there is no cue and no usable sentence span` + `returns null for a gap word when the section has no matching cues`；6 个既有“词落 cue 内 / 有 cue”用例改可空 + 非空断言，验证正常路径行为不变。
  - `hibiki/test/reader/reader_mining_audio_guard_test.dart`：新增源码守卫 `does not gate sentence audio on a non-null lookup cue (BUG-172)`（断言不再含 `if (cue != null && audioFiles != null)`、含 `if (audioFiles != null)`、含 `if (clip != null &&`）；既有守卫的类型断言更新为可空 `final AudioPlaybackRange? clip = miningSentenceAudioRange(`。

### 修复（文件 / 行）

- `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart:2904`（门控放宽）+ `:2906`（`_sentenceAudioMiningCues(cue)`，cue 可空）+ `:2927`（无 range 的可见性 `debugPrint`）。
- `hibiki/lib/src/media/audiobook/mining_audio_clip.dart:19`（`miningSentenceAudioRange` 签名 cue 可空 / 返回可空）+ `_rangeFromSentencePosition`（cue==null 时按 sectionIndex 直接匹配）。
- `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart:2822`（`_sentenceAudioMiningCues` 参数可空）。

### 不回归

- 词确实落在 cue 内：`_lookupCue != null`，`_rangeFromSentencePosition` 走原有 cue-fragment section 校验后用句子 range；句子 range 不可用时回落 `_expandAroundCue` / `_cueRange`，与修复前等价（BUG-144 / 149 的范围逻辑不动）。6 个既有单测全绿验证。
- SRT 书的 `_findCueForSentence` 文本回退（`reader_hibiki_page.dart:2792`，仅 `_srtBookUid != null` 时）与 `_sentenceAudioMiningCues` 的 SRT 章节分支不动。
- 有声书逐字跟随（高亮 / cue 同步）不在本次改动路径内，未触碰。
- `test/media/audiobook/` + `test/reader/` 全组 672 绿；`test/anki` 53 绿；`flutter analyze` 0 issue。

### 验证

- `flutter test test/media/audiobook/mining_audio_clip_test.dart test/reader/reader_mining_audio_guard_test.dart`（13 绿）。
- 反向验证：临时撤掉 `_rangeFromSentencePosition` 的 cue==null 放宽 → gap-word 用例 `-1` 转红，其余绿，证明测试锁定修复逻辑；已恢复。
- `flutter test test/media/audiobook/ test/reader/`（672 绿）+ `flutter test test/anki`（53 绿）+ `flutter analyze`（4 文件 0 issue）+ `dart format`（0 changed）。

### 残留风险

- **真机 / 桌面听声待验**：host 无真 ffmpeg，`extractAudioSegment` 的真实裁剪未在本轮验证（纯逻辑层 + 源码守卫层覆盖）。需真机或桌面用一本绑定有声书音频的书、对落在 cue 空隙的词制卡，验 Anki `SentenceAudio` 字段拿到真实旁白音频段。
