/// 心象（folia cadenza）的时序：行渲染提示（读共享的 `LyricVisualizerRenderHints`）与每个词 / 字 /
/// 整行的包络（`cadenza/cadenzaEnvelopes.ts`）。纯函数，可单测。
///
/// 时间一律用**秒**（double），与 folia 的常数逐一对应，免得换算出错；调用方把歌词显示
/// 毫秒除以 1000 再传进来。
library;

import 'dart:math' as math;

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_render_hints.dart';

export 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_render_hints.dart'
    show
        LyricVisualizerLineTransition,
        LyricVisualizerRenderHints,
        LyricVisualizerTimingClass,
        LyricVisualizerWordReveal;

/// 词的状态。
enum MindscapeWordStatus { waiting, active, passed }

/// 正在唱的词的脉动频率（folia `ACTIVE_PULSE_FREQUENCY`）。
const double mindscapeActivePulseFrequency = 10;

double mindscapeClamp(double v, double lo, double hi) =>
    math.max(lo, math.min(hi, v));

double mindscapeMix(double from, double to, double amount) =>
    from + (to - from) * amount;

double _easeOutCubic(double v) =>
    1 - math.pow(1 - mindscapeClamp(v, 0, 1), 3).toDouble();

double _easeInOutQuad(double v) {
  final double n = mindscapeClamp(v, 0, 1);
  return n < 0.5 ? 2 * n * n : 1 - math.pow(-2 * n + 2, 2).toDouble() / 2;
}

/// 动画用的词时间（秒）。
class MindscapeWordTime {
  const MindscapeWordTime(this.startTime, this.endTime);

  final double startTime;
  final double endTime;
}

/// 一个字形的时间（秒）。
class MindscapeGlyphTime {
  const MindscapeGlyphTime(this.startTime, this.endTime);

  final double startTime;
  final double endTime;
}

/// 行切换的入 / 出时长与唱完后的停顿（folia `LineTransitionTiming`）。
class MindscapeTransitionTiming {
  const MindscapeTransitionTiming({
    required this.enterDuration,
    required this.exitDuration,
    required this.linePassHold,
  });

  final double enterDuration;
  final double exitDuration;
  final double linePassHold;
}

/// 一行解析好的渲染时序（folia `ResolvedLineRenderTiming` + `LineRenderHints`）。
class MindscapeLineTiming {
  const MindscapeLineTiming({
    required this.startTime,
    required this.endTime,
    required this.timingClass,
    required this.lineTransition,
    required this.wordReveal,
    required this.lineRenderEndTime,
    required this.lastWordEndTime,
    required this.transition,
  });

  final double startTime;
  final double endTime;
  final LyricVisualizerTimingClass timingClass;
  final LyricVisualizerLineTransition lineTransition;
  final LyricVisualizerWordReveal wordReveal;

  /// 这一行最晚还能留在屏幕上做离场的时刻。
  final double lineRenderEndTime;
  final double lastWordEndTime;
  final MindscapeTransitionTiming transition;

  double get linePassHold => transition.linePassHold;
}

/// 整行时序（folia `resolveLineRenderTiming`）：分级、离场窗口、入 / 出时长全读共享的
/// [LyricVisualizerRenderHints]（runtime 建行时已算好），这里只换成秒。
MindscapeLineTiming mindscapeLineTimingOf(
  LyricVisualizerRenderHints hints, {
  required double startTime,
  required double endTime,
  required double lastWordEndTime,
}) => MindscapeLineTiming(
  startTime: startTime,
  endTime: endTime,
  timingClass: hints.timingClass,
  lineTransition: hints.lineTransition,
  wordReveal: hints.wordReveal,
  lineRenderEndTime: hints.renderEndMs / 1000,
  lastWordEndTime: lastWordEndTime,
  transition: MindscapeTransitionTiming(
    enterDuration: hints.enterMs / 1000,
    exitDuration: hints.exitMs / 1000,
    linePassHold: hints.passHoldMs / 1000,
  ),
);

/// 按行起止与最后一个词的结束时间（秒）算整行时序（测试 / 没有 runtime 行时用）。
MindscapeLineTiming resolveMindscapeLineTiming({
  required double startTime,
  required double endTime,
  required double? lastWordEndTime,
}) {
  final double lastEnd = lastWordEndTime ?? endTime;
  return mindscapeLineTimingOf(
    LyricVisualizerRenderHints.of(
      startMs: (startTime * 1000).round(),
      endMs: (endTime * 1000).round(),
      lastWordEndMs: (lastEnd * 1000).round(),
    ),
    startTime: startTime,
    endTime: endTime,
    lastWordEndTime: lastEnd,
  );
}

MindscapeWordStatus mindscapeWordStatus(
  double time,
  MindscapeLineTiming line,
  MindscapeWordTime word,
) {
  final double lookahead = switch (line.wordReveal) {
    LyricVisualizerWordReveal.fast => 0.045,
    LyricVisualizerWordReveal.instant => 0,
    LyricVisualizerWordReveal.normal => 0.18,
  };
  final double activeEnd = line.wordReveal == LyricVisualizerWordReveal.instant
      ? line.lineRenderEndTime
      : word.endTime;
  if (time >= word.startTime - lookahead && time <= activeEnd) {
    return MindscapeWordStatus.active;
  }
  if (time > activeEnd) return MindscapeWordStatus.passed;
  return MindscapeWordStatus.waiting;
}

double mindscapeWordProgress(
  double time,
  LyricVisualizerWordReveal reveal,
  MindscapeWordTime word,
) {
  if (reveal == LyricVisualizerWordReveal.instant) {
    return time < word.startTime ? 0 : 1;
  }
  final double minDuration = reveal == LyricVisualizerWordReveal.fast
      ? 0.045
      : 0.01;
  final double duration = math.max(word.endTime - word.startTime, minDuration);
  return mindscapeClamp((time - word.startTime) / duration, 0, 1);
}

double _keyframedGlow(double progress) {
  if (progress <= 0 || progress >= 1) return 0;
  if (progress < 0.3) return _easeOutCubic(progress / 0.3);
  return 1 - mindscapeClamp((progress - 0.3) / 0.7, 0, 1);
}

/// 整词的发光包络（folia `getClassicGlowEnvelope`）。
double mindscapeGlowEnvelope(
  double time,
  MindscapeLineTiming line,
  MindscapeWordTime word,
) {
  if (line.wordReveal == LyricVisualizerWordReveal.instant) {
    if (time < word.startTime || time > line.lineRenderEndTime) return 0;
    return _keyframedGlow(
      mindscapeClamp((time - word.startTime) / 0.067, 0, 1),
    );
  }
  if (line.wordReveal == LyricVisualizerWordReveal.fast) {
    final double duration = math.max(word.endTime - word.startTime, 0.045);
    if (time < word.startTime) return 0;
    if (time <= word.endTime) {
      final double p = mindscapeClamp((time - word.startTime) / duration, 0, 1);
      if (p < 0.14) return _easeOutCubic(p / 0.14);
      if (p < 0.82) return 1;
      return mindscapeMix(1, 0.92, (p - 0.82) / 0.18);
    }
    final double fade = mindscapeClamp((time - word.endTime) / 0.14, 0, 1);
    return math.pow(1 - fade, 2).toDouble();
  }
  final double duration = math.max(word.endTime - word.startTime, 0.1);
  if (time < word.startTime) return 0;
  if (time <= word.endTime) {
    final double p = mindscapeClamp((time - word.startTime) / duration, 0, 1);
    if (p < 0.18) return _easeOutCubic(p / 0.18);
    if (p < 0.9) return 1;
    return mindscapeMix(1, 0.9, (p - 0.9) / 0.1);
  }
  final double fade = mindscapeClamp((time - word.endTime) / 0.9, 0, 1);
  return 0.9 * math.pow(1 - fade, 2).toDouble();
}

/// 逐字发光（folia `getClassicCharGlow`）：每个字起唱后在 6 倍字长里先亮后灭。
double mindscapeCharGlow(
  double time,
  MindscapeWordTime word,
  int glyphIndex,
  int glyphCount,
  List<MindscapeGlyphTime> glyphTimes,
) {
  final double duration = math.max(word.endTime - word.startTime, 0.1);
  final double single = duration / math.max(glyphCount, 1);
  final MindscapeGlyphTime? timing =
      glyphIndex >= 0 && glyphIndex < glyphTimes.length
      ? glyphTimes[glyphIndex]
      : null;
  final double charDuration = timing != null
      ? math.max(timing.endTime - timing.startTime, 0.001)
      : single;
  final double charStart =
      timing?.startTime ?? word.startTime + single * glyphIndex;
  final double elapsed = time - charStart;
  final double active = elapsed <= 0
      ? 0
      : _keyframedGlow(elapsed / (charDuration * 6));
  if (time <= word.endTime) return active;
  final double fade = math
      .pow(1 - mindscapeClamp((time - word.endTime) / 0.9, 0, 1), 2)
      .toDouble();
  return active * fade;
}

/// 正文从底色混到高亮色的比例（folia `getClassicBodyMix`）。
double mindscapeBodyMix(
  double time,
  MindscapeLineTiming line,
  MindscapeWordTime word,
) {
  if (line.wordReveal == LyricVisualizerWordReveal.instant) {
    if (time < word.startTime) return 0;
    return time <= line.lineRenderEndTime ? 1 : 0;
  }
  if (time < word.startTime) return 0;
  if (time <= word.endTime) {
    return mindscapeWordProgress(time, line.wordReveal, word);
  }
  final double fade = mindscapeClamp(
    (time - word.endTime) /
        (line.wordReveal == LyricVisualizerWordReveal.fast ? 0.12 : 0.8),
    0,
    1,
  );
  return 1 - fade;
}

/// 整行的透明度 / 缩放 / 模糊（folia `getClassicLineEnvelope`）。
class MindscapeLineEnvelope {
  const MindscapeLineEnvelope(this.opacity, this.scale, this.blur);

  static const MindscapeLineEnvelope identity = MindscapeLineEnvelope(1, 1, 0);

  final double opacity;
  final double scale;
  final double blur;
}

MindscapeLineEnvelope mindscapeLineEnvelope(
  double time,
  MindscapeLineTiming line,
) {
  final double lineEnd = line.lineRenderEndTime;
  final double passStart =
      math.max(line.lastWordEndTime, line.startTime) + line.linePassHold;
  final double enterDuration = line.transition.enterDuration;
  final double exitDuration = line.transition.exitDuration;
  switch (line.lineTransition) {
    case LyricVisualizerLineTransition.none:
      return MindscapeLineEnvelope.identity;
    case LyricVisualizerLineTransition.fast:
      final double exitStart = math.max(
        math.max(line.startTime + enterDuration + 0.01, passStart),
        lineEnd - exitDuration,
      );
      final double enter = _easeOutCubic(
        mindscapeClamp((time - line.startTime) / enterDuration, 0, 1),
      );
      double opacity = mindscapeMix(0.65, 1, enter);
      double scale = mindscapeMix(0.97, 1, enter);
      double blur = mindscapeMix(4, 0, enter);
      final double exit = _easeOutCubic(
        mindscapeClamp((time - exitStart) / exitDuration, 0, 1),
      );
      if (exit > 0) {
        opacity = mindscapeMix(opacity, 0, exit);
        scale = mindscapeMix(scale, 1.03, exit);
        blur = math.max(blur, mindscapeMix(0, 6, exit));
      }
      return MindscapeLineEnvelope(mindscapeClamp(opacity, 0, 1), scale, blur);
    case LyricVisualizerLineTransition.normal:
      final double preEnter = math.min(0.1, enterDuration * 0.35);
      final double enter = _easeOutCubic(
        mindscapeClamp(
          (time - (line.startTime - preEnter)) / (enterDuration + preEnter),
          0,
          1,
        ),
      );
      double opacity = mindscapeMix(0, 1, enter);
      double scale = mindscapeMix(0.9, 1, enter);
      double blur = mindscapeMix(10, 0, enter);
      final double exitStart = math.max(passStart, lineEnd - exitDuration);
      final double exit = _easeOutCubic(
        mindscapeClamp((time - exitStart) / exitDuration, 0, 1),
      );
      if (exit > 0) {
        opacity *= 1 - exit;
        scale = mindscapeMix(scale, 1.1, exit);
        blur = math.max(blur, mindscapeMix(0, 20, exit));
      }
      return MindscapeLineEnvelope(mindscapeClamp(opacity, 0, 1), scale, blur);
  }
}

/// 唱过的词向外漂开的进度（folia `getClassicPassedDrift`，5 秒走完）。
double mindscapePassedDrift(double time, MindscapeWordTime word) {
  if (time <= word.endTime) return 0;
  return _easeInOutQuad(mindscapeClamp((time - word.endTime) / 5, 0, 1));
}

/// folia `buildDomTextShadow` 三层 40px 阴影各自的透明度。
(double, double, double) mindscapeGlowAlphas(double intensity) {
  final double g = mindscapeClamp(intensity, 0, 1.6);
  if (g <= 0.01) return (0, 0, 0);
  return (
    math.min(0.98, g),
    math.min(0.92, g * 0.92),
    math.min(0.35, g * 0.26),
  );
}
