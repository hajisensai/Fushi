/// 小说有声书的句间停顿（设计 §8）：小说没有页段，时间模型只用「转场基础值 + 一拍」
/// 那一半；段落 / 场景停顿沿用 [TtsPausePreset] 作默认。
///
/// 一章算不算「按演出稿」由调用方定（目前 = 这章跑过选角标注）。没按演出稿的章与
/// 以前完全一样：句间停顿只看段落 / 场景边界（[TtsPausePreset.afterSentence]）。
///
/// 按演出稿的章，第 k 句之后的停顿：
/// - 同段内：转场基础值（[castTransitionBaseMs]：内心 ↔ 说出口 900 > 换人 450 > 同人
///   300）；
/// - 段落结束 / 场景分隔：预设的段落 / 场景停顿与转场基础值取大（日文小说每句台词
///   常自成一段，段落停顿不能把「内心 ↔ 说出口」的长转场吃掉）；
/// - 再加该句的一拍（[TtsCastLine.beatMs]，章尾也加）；
/// - 预设是 [TtsPausePreset.none]（用户要求不额外插停顿）时转场基础值为 0，只留
///   一拍——一拍是逐句明确给的演出，不是默认停顿。
library;

import 'package:fushi_engine/tts/cast/cast_line_direction.dart';
import 'package:fushi_engine/tts/cast/cast_line_kind.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:fushi_engine/tts/render/tts_pause.dart';

/// 算停顿要用的一句：分句计划给的段落 / 场景边界 + 选角表里这一句的行（没有 = 旁白）。
typedef TtsTimedSentence = ({
  bool endsParagraph,
  bool sceneBreakAfter,
  TtsCastLine? line,
});

/// 一章各处的停顿（毫秒），长度 = 句数 + 1：`[0]` 章首、`[k]`（1 ≤ k < n）第 k-1
/// 句之后、`[n]` 章尾。[directed] = 这章按演出稿算（见库注释）。
List<int> ttsCastChapterGapsMs({
  required List<TtsTimedSentence> sentences,
  required TtsPausePreset preset,
  required bool directed,
}) {
  final int n = sentences.length;
  return <int>[
    preset.chapterLeadMs,
    for (int k = 0; k + 1 < n; k++)
      directed
          ? ttsDirectedGapAfterMs(
              sentence: sentences[k],
              next: sentences[k + 1].line,
              preset: preset,
            )
          : preset.afterSentence(
              endsParagraph: sentences[k].endsParagraph,
              sceneBreakAfter: sentences[k].sceneBreakAfter,
            ),
    if (n > 0)
      preset.chapterTailMs + (directed ? _beatOf(sentences[n - 1].line) : 0)
    else
      preset.chapterTailMs,
  ];
}

/// 按演出稿时，一句之后（下一句是 [next]，null = 没标的旁白）的停顿。
int ttsDirectedGapAfterMs({
  required TtsTimedSentence sentence,
  required TtsCastLine? next,
  required TtsPausePreset preset,
}) {
  final int transition = preset == TtsPausePreset.none
      ? 0
      : castTransitionBaseMs(
          speaker: _speakerOf(sentence.line),
          kind: _kindOf(sentence.line),
          nextSpeaker: _speakerOf(next),
          nextKind: _kindOf(next),
        );
  final int base;
  if (sentence.sceneBreakAfter) {
    base = transition > preset.sceneMs ? transition : preset.sceneMs;
  } else if (sentence.endsParagraph) {
    base = transition > preset.paragraphMs ? transition : preset.paragraphMs;
  } else {
    base = transition;
  }
  return base + _beatOf(sentence.line);
}

String _speakerOf(TtsCastLine? line) => line?.speaker ?? kTtsNarrator;

CastLineKind _kindOf(TtsCastLine? line) =>
    line?.effectiveKind ?? CastLineKind.narration;

int _beatOf(TtsCastLine? line) => line?.beatMs ?? 0;
