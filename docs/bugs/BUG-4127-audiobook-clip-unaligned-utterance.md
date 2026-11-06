## BUG-4127 · 有声书导出片段视频：第二句只有声音没字幕（对齐数据把漏听台词并入下一句，导出窗口本身正确）
- **报告**：2026-11-01（用户：开发者本人，反馈 Q8uRYyNSLO，Windows 3.2.0-debug.22671）
- **真实性**：✅ 现象为真；❌ 导出侧（`clip_export` / 帧计划 / cue 选择）未复现缺陷。根因在**对齐数据**，不在导出。
  - 日志 `[ReaderFushi] export-clip start: text="「お手伝いしましょうか？」" audioFileIndex=0 startMs=13044300 endMs=13048610 durationMs=4310 … 安達としまむら3.m4b dynamicCues=1`。
  - 本机库 `audio_cues`（book `安達としまむら3`，对齐源 `transcript.srt`，`window=200 threshold=0.6`）：
    - #3293 `「お手伝いしましょうか？」` 13044420–13048010（`fushi-cue://s=20&ns=8561&ne=8571`）
    - #3294 `「いーらーん」引っ剝がして部屋に戻る。` 13049720–13051320（`ns=8571&ne=8587`）
  - 导出窗口 = #3293 的 `[start − kMiningHeadPadMs(120), end + kClipExportTailPadMs(600)]` 一分不差（13044300 / 13048610），即 delayMs=0；
    窗口与帧计划同源（`fushi/lib/src/media/audiobook/mining_audio_clip.dart` `clipExportGlobalRange` +
    `fushi/lib/src/pages/implementations/reader_fushi/audiobook.part.dart` `_buildAudiobookClipPlan`），AI 总结里「delayMs 平移把下一句包进去」的假设不成立。
  - `ffmpeg -ss 13044.300 -t 7.1 … -af silencedetect=noise=-30dB:d=0.2` 实测窗口内有**两段**发声：0.26–1.78 s（お手伝いしましょうか）、2.27–3.44 s（いーらーん），
    随后静音到 5.52 s 才是「引っ剝がして部屋に戻る」。也就是说 #3293 的时间段里本来就念了两句台词。
  - `transcript.srt`（设备端 ASR 产物）对应 cue 4149 `おてつだいしましょうか？` 03:37:24.544–27.856：ASR **漏听了「いーらーん」**，但段时间戳盖住了它；
    匹配器只认听到的字，把正文「いーらーん」并进了下一条 ASR cue（4150 `引っぺがして部屋に戻る。`，其音频里没有这句）。
  - 结果：导出 #3293 时音频里有两句、卡片只有第一句；而点 #3294 播放时高亮着「いーらーん」却听不到它。导出代码按 cue 数据做的是对的。
- **[ ] ① 未修复** — 修复层在对齐，不在导出：
  - ASR 漏字本身属上游 `hajisensai/fushi-subtitles`（asr-assembly.md：ASR 算法一律去上游改）。
  - 本仓可落地的一层是 `packages/fushi_audio/lib/src/matching/cue_sentence_resegmenter.dart` 的合缝 `_closeGaps`：它已有「前一条末 token 后有长段没出字 → 缝归前一条」的证据判据（`_fallbackCut` / `_unheardTailMs`），
    但只在缝内第一个切点**认领不下**时才查；第一个切点认领得起时直接按句界切，不看 token 证据。不过本例**用不上**这条：本书目录里没有 `transcript.tokens.jsonl`（token sidecar），
    `attachAsrCueTokenTiming` 挂不上，重切器整段不参与（`_eligible` 要求 token 时间）。
- **[ ] ② 未加自动化测试** — 根因层未定前不写。
- **备注**：证据缺口（定修复层所需）：
  1. 本书当时对齐有没有 token sidecar（目录里现在只有 `transcript.srt` 与 `安達としまむら3.srt`；库里 cue 起止与现存 `transcript.srt` 差 40–150 ms，说明落库时用的不是这份原样时间，可能是带 token 的旧一次转录）；
  2. 是匹配器哪一步把 #3294 的起点向前扩到 `ns=8571`（native `ffc_text_cue_match` 的 Dice 滑窗 / `cueTailOverlap` 回退，还是 `AnchorGapFiller` 回填）——需在本机拿这本 EPUB + `transcript.srt` 重跑一遍 `EpubSrtMatcher` 并打印该段 `CueMatch`。
  拿到这两条再决定修在匹配器（漏听台词归时长富余的一侧）还是上游 ASR（不漏听 / 按 VAD 切段）。导出侧无需改动。
