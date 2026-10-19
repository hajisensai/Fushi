/// S5 显示后处理的生产实现：标点统一为全角 + 多句长条按句末拆分（spec
/// `2026-10-19-video-asr-llm-subtitle-pipeline` 第 3 节 S5）。
///
/// 拆分算法在上游 `fushi_asr_subtitles` 的 [splitLongSubtitleCuesWithTokenTimings]
/// （切点取 token 时间，没有时按字数比例），本文件只把管线的 [SubtitleDraftCue]
/// 换成上游的 cue + token 时间、再换回来。
///
/// **token 时间只写进 `final.json`**：拆出来的每片带着落在它里面的 token（偏移
/// 已改成相对这一片的起点），留作排查与日后重拆的依据。导出的 `<视频名>.ja.srt`
/// 旁边**有意不写** tokens sidecar：上游的 sidecar 读取（`readCueTokenTimings`）
/// 只认转录任务目录里的 `transcript.srt`，播放页加载外挂字幕也不读它——没有消费方，
/// 写了只是一份会与 SRT 逐行错位风险并存的死文件。
library;

import 'package:fushi_asr_core/asr_core.dart' show AsrCueTokenTiming;
import 'package:fushi_asr_subtitles/asr_subtitles.dart'
    show
        SubtitleCue,
        SubtitleCueWithTokenTiming,
        SubtitleLongCueSplitOptions,
        normalizeSubtitlePunctuationToFullWidth,
        splitLongSubtitleCuesWithTokenTimings;
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_draft.dart';

/// 管线默认的显示拆分（`VideoSubtitlePipeline.displaySplitter` 的生产默认值）。
///
/// - 先把 `!?` 统一成全角（S3/S4 已做过的再做一遍无副作用；AI 关闭时识别稿只经过
///   这一步）；
/// - 超过 7 s 或 40 字且含多句的条目在句末拆开，切点取下一句首个 token 的开始时间
///   减 0.1 s；没有句末但过长的在最长停顿（≥0.35 s）处切；
/// - 没拆的条目原样保留（说话人、候选稿、token 时间都不动）；拆出来的各片沿用原
///   条目的说话人，不再带候选稿（候选稿是整条的，拆开后对不上片）。
///
/// 只改时间切分与文字分配，不增删正文。
List<SubtitleDraftCue> splitSubtitleDraftCuesForDisplay(
  List<SubtitleDraftCue> cues, {
  SubtitleLongCueSplitOptions options = const SubtitleLongCueSplitOptions(),
}) {
  final List<SubtitleDraftCue> normalized = <SubtitleDraftCue>[
    for (final SubtitleDraftCue c in cues)
      c.copyWith(text: normalizeSubtitlePunctuationToFullWidth(c.text)),
  ];
  final List<SubtitleDraftCue> out = <SubtitleDraftCue>[];
  for (final SubtitleDraftCue cue in normalized) {
    final List<SubtitleCueWithTokenTiming> pieces =
        splitLongSubtitleCuesWithTokenTimings(
          <SubtitleCue>[
            SubtitleCue(
              index: 1,
              startMs: cue.startMs,
              endMs: cue.endMs,
              text: cue.text,
            ),
          ],
          tokenTimings: <AsrCueTokenTiming?>[cue.tokenTiming],
          options: options,
        );
    if (pieces.length == 1) {
      out.add(cue);
      continue;
    }
    for (final SubtitleCueWithTokenTiming piece in pieces) {
      out.add(
        SubtitleDraftCue(
          startMs: piece.cue.startMs,
          endMs: piece.cue.endMs,
          text: piece.cue.text,
          speaker: cue.speaker,
          tokenTiming: piece.tokenTiming,
        ),
      );
    }
  }
  return out;
}
