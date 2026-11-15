## BUG-4182 · 有声书导出片段视频：第二句只有声音没字幕（对齐数据把漏听台词并入下一句，导出窗口本身正确）
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
- **[x] ① 已修复** — `a2a797e45b`（修在本仓匹配器的合缝，不在导出、不在上游 ASR）。
  - 补证据（2026-11-10）：token sidecar 在转录任务目录 `support/asr_jobs/c69e62d5…/transcript.tokens.jsonl`（行数 = cue 数 8008，`attachAsrCueTokenTiming` 挂得上，重切器参与了；书目录里那份 `transcript.srt` 只是拷贝）。
    用该书 EPUB + 这份 `transcript.srt` / sidecar 重跑 `EpubSrtMatcher`（window=200, threshold=0.6）→ `AnchorGapFiller` → `CueSentenceResegmenter`，输出与库里 #3293/#3294 逐字一致：
    - native 第一遍：cue 4148 `おてつだいしましょうか？` → `ns=8561 ne=8571`，cue 4149 `引っぺがして部屋に戻る。` → `ns=8576 ne=8587`；**匹配器没把「いーらーん」给任何一侧**，留成缝 `[8571,8576)`，回填也没动；
    - 合缝 `_closeGaps`：缝内第一个切点就是缝起点 8571（`？」「` 句界），后一条 1.6 s 认领 16 字不超读速上限 → 直接按它切，整段推给后一条 → `ns=8571`。没看 token 证据：前一条末 token 在 1394 ms、cue 到 3312 ms 才收声（1.9 s 没出字），后一条首 token 偏移 0。
  - 归属：ASR 漏听（raw 段 `13044058–13048026` 只解出 11 个 token，末 token 13045938）确属上游，但上游漏字是常态、本仓匹配器的职责就是用时间证据把漏听正文归给正在发声的 cue——这次错在本仓 `packages/fushi_audio/lib/src/matching/cue_sentence_resegmenter.dart` 合缝（`_closeGaps` 无中间 cue 分支，修前 :277 `fits(first) ? first : _fallbackCut(...)`）：时长证据只在第一个切点认领不下时才看。
  - 修复（`cue_sentence_resegmenter.dart:276-300`）：前一条「没出字的发声时长」比后一条开头多出 `forwardPauseMs` 以上（`_unheardSide`，与 `_fallbackCut` / 片归属同一判据）时，把第一个切点之后**到最后一个整句 / 整段引号边界**（`_lastUtteranceBoundary` + `_SectionGaps.endsUtteranceAt`：句末标点或引号开 / 合 / 换对）的正文归前一条，认领不下仍走原路径。只按整句挪：没出字时长也可能是末字拖长音（「んー……ま、いっか」实测「ま」念在两条之间），句中逗号后的下一句开头半截不拆过去。
  - 整书对拍（修前 / 修后同一输入，8008 cue → 6372 cue）：只变 3 处，`ffmpeg silencedetect` 逐处核过都是漏听的台词确实在前一条的发声区间里：#3293「いーらーん」、「…ないや｜じゃあ」（前一条尾 11849.80–11850.74 s 有一段发声）、「あはははははっははー｜えぇぇ」（笑声全在前两条里，后一条「え」只有 0.5 s）。160 个合成用例 × 2 档 `cue_resegmenter_golden` 夹具逐位不变。
- **[x] ② 已加自动化测试** — `cba5310fa1`：`packages/fushi_audio/test/matching/cue_sentence_resegmenter_test.dart` 组「合缝：漏听的整句台词按没出字时长归前一条（BUG-4182）」——本书真实 token 时间的最小复现（两句正文、ASR 只给一句 token、时间覆盖两句 → 两条 cue，`いーらーん` 在前一条，换正文后 `「お手伝いしましょうか？」「いーらーん」` / `引っ剝がして部屋に戻る。`），外加拖长音反例（「んー……ま、いっか」缝尾半句不拆过去）。测试未在本分支运行，统一在合并后验证。
- **备注**：导出侧（`clipExportGlobalRange` / `_buildAudiobookClipPlan`）无缺陷、未改。已落库的书要重新对齐（重新「使用字幕」/ 重匹配）才会换上新切分。
