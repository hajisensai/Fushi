/// 回环的字素时间轴（移植 folia `claddagh/claddaghTimeline.ts`）：给零时长的空白字匀出时长、
/// 按时间插值出小数下标、整行偏移角与行播放进度。纯 Dart，时间一律毫秒（folia 用秒）。
library;

import 'dart:math' as math;

/// 一个字素的起止（可变：[adjustCladdaghTimeline] 会挪动邻字的边界）。
class CladdaghTiming {
  CladdaghTiming({
    required this.char,
    required this.startMs,
    required this.endMs,
  });

  final String char;
  double startMs;
  double endMs;

  CladdaghTiming copy() =>
      CladdaghTiming(char: char, startMs: startMs, endMs: endMs);
}

/// 排到环上的一个字素：时间 + 名义角（弧度，整行居中）+ 整行压缩比。
class CladdaghGlyph {
  const CladdaghGlyph({
    required this.char,
    required this.startMs,
    required this.endMs,
    required this.nominalAngle,
    required this.scaleFactor,
  });

  final String char;
  final double startMs;
  final double endMs;
  final double nominalAngle;

  /// 整行弧长超过上限时的压缩比（字号一并缩）。
  final double scaleFactor;
}

double claddaghClamp(double value, double min, double max) =>
    math.max(min, math.min(max, value));

final RegExp _cjk = RegExp(r'[一-龥぀-ヿ가-힯]');

/// folia `isCJKChar`：只认常用汉字、假名、谚文（比运行时的 CJK 判定窄，按原样保留）。
bool claddaghIsCjkChar(String char) => _cjk.hasMatch(char);

/// 句子的视觉长度：CJK 记 1，其余（按 UTF-16 码元）记 0.5。
double claddaghVisualLength(String text) {
  double score = 0;
  for (int i = 0; i < text.length; i++) {
    score += claddaghIsCjkChar(text[i]) ? 1.0 : 0.5;
  }
  return score;
}

/// 零时长的字（空白、无时值的标点）向邻字借时长，每个至少 60ms，再在空档里均分。
List<CladdaghTiming> adjustCladdaghTimeline(
  List<CladdaghTiming> timeline,
  double lineStartMs,
  double lineEndMs,
) {
  if (timeline.isEmpty) return timeline;
  final List<CladdaghTiming> adjusted = <CladdaghTiming>[
    for (final CladdaghTiming t in timeline) t.copy(),
  ];
  final int n = adjusted.length;
  int i = 0;
  while (i < n) {
    if (adjusted[i].startMs != adjusted[i].endMs) {
      i++;
      continue;
    }
    int j = i;
    while (j < n && adjusted[j].startMs == adjusted[j].endMs) {
      j++;
    }
    final int gapCount = j - i;
    double gapStart = i > 0 ? adjusted[i - 1].endMs : lineStartMs;
    double gapEnd = j < n ? adjusted[j].startMs : lineEndMs;
    final double minNeeded = gapCount * 60.0;
    double duration = gapEnd - gapStart;
    if (duration < minNeeded) {
      final double deficit = minNeeded - duration;
      if (i > 0 && j < n) {
        final double half = deficit / 2;
        final double prevDuration =
            adjusted[i - 1].endMs - adjusted[i - 1].startMs;
        final double prevSteal = math.min(
          half,
          math.max(0.0, prevDuration - 40),
        );
        final double nextDuration = adjusted[j].endMs - adjusted[j].startMs;
        final double nextSteal = math.min(
          deficit - prevSteal,
          math.max(0.0, nextDuration - 40),
        );
        gapStart -= prevSteal;
        gapEnd += nextSteal;
        adjusted[i - 1].endMs = gapStart;
        adjusted[j].startMs = gapEnd;
      } else if (i > 0) {
        final double prevDuration =
            adjusted[i - 1].endMs - adjusted[i - 1].startMs;
        final double prevSteal = math.min(
          deficit,
          math.max(0.0, prevDuration - 40),
        );
        gapStart -= prevSteal;
        adjusted[i - 1].endMs = gapStart;
      } else if (j < n) {
        final double nextDuration = adjusted[j].endMs - adjusted[j].startMs;
        final double nextSteal = math.min(
          deficit,
          math.max(0.0, nextDuration - 40),
        );
        gapEnd += nextSteal;
        adjusted[j].startMs = gapEnd;
      }
      duration = gapEnd - gapStart;
    }
    final double unit = duration > 0 ? duration / gapCount : 0;
    for (int k = i; k < j; k++) {
      final int idx = k - i;
      adjusted[k].startMs = gapStart + unit * idx;
      adjusted[k].endMs = gapStart + unit * (idx + 1);
    }
    i = j;
  }
  return adjusted;
}

/// 此刻唱到第几个字（小数）；过了最后一个字的起点仍继续外推，免得环停住。
double claddaghFractionalIndex(
  List<CladdaghGlyph> timeline,
  double t, [
  double? renderEndMs,
]) {
  if (timeline.isEmpty) return 0;
  final bool hasEnd = renderEndMs != null && renderEndMs.isFinite;
  if (timeline.length == 1) {
    final CladdaghGlyph item = timeline.first;
    final double targetEnd = hasEnd ? renderEndMs : item.endMs;
    final double dur = math.max(200.0, targetEnd - item.startMs);
    if (t <= item.startMs) return 0;
    return (t - item.startMs) / dur;
  }
  if (t <= timeline.first.startMs) return 0;
  final int lastIdx = timeline.length - 1;
  final CladdaghGlyph lastItem = timeline[lastIdx];
  if (t >= lastItem.startMs) {
    if (hasEnd && renderEndMs > lastItem.startMs) {
      final double progress = claddaghClamp(
        (t - lastItem.startMs) / (renderEndMs - lastItem.startMs),
        0,
        1,
      );
      return lastIdx + progress * 2.0;
    }
    final CladdaghGlyph prevItem = timeline[lastIdx - 1];
    final double itemDur = lastItem.endMs - lastItem.startMs;
    final double gapDur = lastItem.startMs - prevItem.startMs;
    final double stepDur = itemDur > 0
        ? itemDur
        : (gapDur > 0 ? gapDur : 500.0);
    final double progress = (t - lastItem.startMs) / stepDur;
    // 最后一个字之后最多再转 1.8 个字。
    return lastIdx + math.min(progress, 1.8);
  }
  for (int i = 0; i < lastIdx; i++) {
    final double s = timeline[i].startMs;
    final double e = timeline[i + 1].startMs;
    if (t >= s && t < e) {
      if (e == s) return i.toDouble();
      return i + (t - s) / (e - s);
    }
  }
  return lastIdx.toDouble();
}

/// 整行沿环转过的角度：把正在唱的字转到正前方（小数下标在名义角之间插值）。
double claddaghLineWordOffset(
  List<CladdaghGlyph> spacing,
  double t, [
  double? renderEndMs,
]) {
  if (spacing.isEmpty) return 0;
  final double fi = claddaghFractionalIndex(spacing, t, renderEndMs);
  final int lastIdx = spacing.length - 1;
  if (fi <= lastIdx) {
    final int intPart = fi.floor();
    final double frac = fi - intPart;
    final double a = spacing[intPart].nominalAngle;
    final double b = spacing[math.min(intPart + 1, lastIdx)].nominalAngle;
    return a + (b - a) * frac;
  }
  final double lastAngle = spacing[lastIdx].nominalAngle;
  final double prevAngle = spacing[math.max(0, lastIdx - 1)].nominalAngle;
  return lastAngle + (lastAngle - prevAngle) * (fi - lastIdx);
}

/// 行的播放进度 0–1。
double claddaghLinePlaybackProgress(
  List<CladdaghGlyph> spacing,
  double t, [
  double? renderEndMs,
]) {
  if (spacing.isEmpty) return 0;
  if (spacing.length == 1) {
    final CladdaghGlyph item = spacing.first;
    final double targetEnd = renderEndMs != null && renderEndMs.isFinite
        ? renderEndMs
        : item.endMs;
    final double duration = math.max(1.0, targetEnd - item.startMs);
    return claddaghClamp((t - item.startMs) / duration, 0, 1);
  }
  final double fi = claddaghFractionalIndex(spacing, t, renderEndMs);
  return claddaghClamp(fi / math.max(1, spacing.length - 1), 0, 1);
}
