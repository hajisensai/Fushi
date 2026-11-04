## BUG-4110 · 短片（识别稿少于 30 行）的外挂字幕在自动字幕生成里整条被丢
- **报告**：2026-11-05（用户：#2840 PR 缺口「识别稿少于 30 行的短片仍不收外挂字幕」，拍板去上游改）
- **真实性**：✅ 真 bug。根因在上游 hajisensai/fushi-subtitles `packages/asr_subtitles/lib/src/subtitle_reference_alignment.dart:991`（`kMinReferenceCues = 30`）与 `:1078`（`groupReferenceTracks` 按它整条滤掉参考轨）：这条绝对门槛本意是挡 forced / 特效字轨，但台词少于 30 句的短片的整份参考也被挡掉。本仓 `packages/fushi_engine/lib/media/video/subtitle/asr_proofread/subtitle_evidence_loader.dart:237` 拿 ASR 识别稿当参考，短片因此一条外挂字幕都收不进来；`embedded_reference_subtitle_sync.dart:121` 也复用了同一门槛。
- **[x] ① 已修复** — 上游 hajisensai/fushi-subtitles#29：删 `kMinReferenceCues`，改为 `isUsableReferenceTrack`（参考 ≥ 对齐下限 5 条，且 ≥ 0.2 × 目标去重 cue 数；forced 轨无论片长都是台词的稀疏子集，所以照样挡住）。本仓升钉的 sha，删掉证据收集里的 30 行早退，`syncSubtitleBytesToReferences` 改用同一判据判 `noReference`。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/subtitle/asr_proofread/subtitle_evidence_loader_test.dart`「短片（识别稿少于 30 行）」（90 秒短片：对得上的外挂轨收下并改写到本片时间轴，别的短片的字幕不收）；上游 `packages/asr_subtitles/test/subtitle_reference_alignment_test.dart`「短片（台词少于 30 句）」与「整份台词的稀疏子集不当参考」。
- **备注**：没做真机 / 模拟器复测。
