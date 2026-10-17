/// 「制作有声书」的语音识别校对（纯函数部分）：把一章成品的识别结果按句的时间窗
/// 分到各句，与原文比相似度，差得远的标出来。
///
/// 一章只识别一次（不是逐句），识别出的 token 按「cue 起点 + token 偏移」落到绝对
/// 时间，再归到所在句的 `[startMs, endMs)` 窗里。
library;

import 'dart:math' as math;

import 'package:fushi_asr_core/asr_core.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_engine/tts/render/tts_render_queue.dart';

/// 识别出的一小段文本及其在本章文件里的时刻。
class TtsHeardToken {
  const TtsHeardToken({required this.atMs, required this.text});

  final int atMs;
  final String text;
}

/// 识别 cue（本章文件时间轴）→ 带时刻的 token。
///
/// 有逐 token 时间（[timings] 与 [asrCues] 等长）时按 token 落时刻；没有时整条 cue
/// 落在它的中点——粒度粗，但仍是同一套窗口归属规则。
List<TtsHeardToken> ttsHeardTokensFromAsr(
  List<AudioCue> asrCues,
  List<AsrCueTokenTiming>? timings,
) {
  final bool useTokens = timings != null && timings.length == asrCues.length;
  final List<TtsHeardToken> out = <TtsHeardToken>[];
  for (int i = 0; i < asrCues.length; i++) {
    final AudioCue cue = asrCues[i];
    final AsrCueTokenTiming? timing = useTokens ? timings[i] : null;
    if (timing != null && !timing.isEmpty) {
      for (int t = 0; t < timing.length; t++) {
        out.add(
          TtsHeardToken(
            atMs: cue.startMs + timing.offsetsMs[t],
            text: timing.tokens[t],
          ),
        );
      }
    } else {
      out.add(
        TtsHeardToken(atMs: (cue.startMs + cue.endMs) ~/ 2, text: cue.text),
      );
    }
  }
  return out;
}

/// 把 token 归到时间窗（`[startMs, endMs)`，窗按时间升序且不重叠），返回每个窗
/// 听到的文本。落在所有窗外的 token 丢弃。
List<String> ttsHeardTextPerWindow(
  List<TtsHeardToken> tokens,
  List<({int startMs, int endMs})> windows,
) {
  final List<StringBuffer> buffers = <StringBuffer>[
    for (int i = 0; i < windows.length; i++) StringBuffer(),
  ];
  final List<TtsHeardToken> sorted = List<TtsHeardToken>.of(tokens)
    ..sort((TtsHeardToken a, TtsHeardToken b) => a.atMs.compareTo(b.atMs));
  int w = 0;
  for (final TtsHeardToken token in sorted) {
    while (w < windows.length && token.atMs >= windows[w].endMs) {
      w++;
    }
    if (w >= windows.length) break;
    if (token.atMs < windows[w].startMs) continue;
    buffers[w].write(token.text);
  }
  return <String>[for (final StringBuffer b in buffers) b.toString()];
}

/// 编辑距离（按 UTF-16 码元；归一化后的日文文本基本都在 BMP 内）。
int ttsLevenshtein(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  List<int> prev = List<int>.generate(b.length + 1, (int j) => j);
  List<int> curr = List<int>.filled(b.length + 1, 0);
  for (int i = 1; i <= a.length; i++) {
    curr[0] = i;
    final int ca = a.codeUnitAt(i - 1);
    for (int j = 1; j <= b.length; j++) {
      final int cost = ca == b.codeUnitAt(j - 1) ? 0 : 1;
      curr[j] = math.min(
        math.min(curr[j - 1] + 1, prev[j] + 1),
        prev[j - 1] + cost,
      );
    }
    final List<int> swap = prev;
    prev = curr;
    curr = swap;
  }
  return prev[b.length];
}

/// 归一化后 `1 - 编辑距离 / 较长者长度`。两边归一化后都为空视为 1。
double ttsTextSimilarity(String heard, String expected) {
  final String a = AudioTextNormalizer.normalize(heard);
  final String b = AudioTextNormalizer.normalize(expected);
  final int maxLen = math.max(a.length, b.length);
  if (maxLen == 0) return 1;
  return 1 - ttsLevenshtein(a, b) / maxLen;
}

/// 一句的相似度：与显示原文、合成文本（读音）各比一次取高者——识别器可能写出
/// 汉字也可能写出假名。
double ttsSentenceSimilarity({
  required String heard,
  required String text,
  required String spokenText,
}) => math.max(
  ttsTextSimilarity(heard, text),
  ttsTextSimilarity(heard, spokenText),
);

/// 校对用的一句：计划下标 + 原文 + 合成文本 + 本章文件内的时间窗。
class TtsVerifySentence {
  const TtsVerifySentence({
    required this.planIndex,
    required this.text,
    required this.spokenText,
    required this.startMs,
    required this.endMs,
  });

  final int planIndex;
  final String text;
  final String spokenText;
  final int startMs;
  final int endMs;
}

/// 一章的校对：低于 [threshold] 的句标出来。
List<TtsRenderFlag> flagTtsChapterSentences({
  required List<TtsVerifySentence> sentences,
  required List<TtsHeardToken> heard,
  double threshold = kAsrSuggestedSimilarityThreshold,
}) {
  final List<String> texts = ttsHeardTextPerWindow(
    heard,
    <({int startMs, int endMs})>[
      for (final TtsVerifySentence s in sentences)
        (startMs: s.startMs, endMs: s.endMs),
    ],
  );
  final List<TtsRenderFlag> flags = <TtsRenderFlag>[];
  for (int i = 0; i < sentences.length; i++) {
    final double similarity = ttsSentenceSimilarity(
      heard: texts[i],
      text: sentences[i].text,
      spokenText: sentences[i].spokenText,
    );
    if (similarity < threshold) {
      flags.add(
        TtsRenderFlag(
          sentence: sentences[i].planIndex,
          similarity: similarity,
          heard: texts[i],
        ),
      );
    }
  }
  return flags;
}
