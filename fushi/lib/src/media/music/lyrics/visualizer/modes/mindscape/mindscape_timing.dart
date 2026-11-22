/// 心象（folia cadenza）的时序：行渲染提示（`utils/lyrics/renderHints.ts`）与每个词 / 字 /
/// 整行的包络（`cadenza/cadenzaEnvelopes.ts`）。纯函数，可单测。
///
/// 时间一律用**秒**（double），与 folia 的常数逐一对应，免得换算出错；调用方把歌词显示
/// 毫秒除以 1000 再传进来。
library;

import 'dart:math' as math;

/// 行的时长档：极短 / 短 / 正常（folia `LineTimingClass`）。
enum MindscapeTimingClass { normal, short, micro }

/// 行切换方式（folia `LineTransitionMode`）。
enum MindscapeLineTransition { normal, fast, none }

/// 逐词显现方式（folia `WordRevealMode`）。
enum MindscapeWordReveal { normal, fast, instant }

/// 词的状态。
enum MindscapeWordStatus { waiting, active, passed }

const double _microLineThreshold = 0.10;
const double _shortLineThreshold = 0.18;
const double _microLineRenderFloor = 0.067;

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
  final MindscapeTimingClass timingClass;
  final MindscapeLineTransition lineTransition;
  final MindscapeWordReveal wordReveal;

  /// 这一行最晚还能留在屏幕上做离场的时刻。
  final double lineRenderEndTime;
  final double lastWordEndTime;
  final MindscapeTransitionTiming transition;

  double get linePassHold => transition.linePassHold;
}

MindscapeTransitionTiming mindscapeTransitionTiming(
  double rawDuration,
  MindscapeLineTransition mode,
  MindscapeWordReveal reveal,
) {
  switch (mode) {
    case MindscapeLineTransition.none:
      return const MindscapeTransitionTiming(
        enterDuration: 0,
        exitDuration: 0,
        linePassHold: 0,
      );
    case MindscapeLineTransition.fast:
      return MindscapeTransitionTiming(
        enterDuration: mindscapeClamp(rawDuration * 0.45, 0.045, 0.06),
        exitDuration: mindscapeClamp(rawDuration * 0.22, 0.03, 0.04),
        linePassHold: reveal == MindscapeWordReveal.instant ? 0 : 0.03,
      );
    case MindscapeLineTransition.normal:
      final double d = math.max(rawDuration, 0.12);
      return MindscapeTransitionTiming(
        enterDuration: math.min(0.42, math.max(0.22, d * 0.34)),
        exitDuration: math.min(0.32, math.max(0.18, d * 0.18)),
        linePassHold: reveal == MindscapeWordReveal.instant ? 0 : 0.06,
      );
  }
}

/// 按行起止与最后一个词的结束时间算出整行时序（folia `buildLineRenderHints` +
/// `resolveLineRenderTiming`）。
MindscapeLineTiming resolveMindscapeLineTiming({
  required double startTime,
  required double endTime,
  required double? lastWordEndTime,
}) {
  final double rawDuration = math.max(endTime - startTime, 0);
  final MindscapeTimingClass cls = rawDuration < _microLineThreshold
      ? MindscapeTimingClass.micro
      : rawDuration < _shortLineThreshold
      ? MindscapeTimingClass.short
      : MindscapeTimingClass.normal;
  final MindscapeLineTransition transitionMode = switch (cls) {
    MindscapeTimingClass.micro => MindscapeLineTransition.none,
    MindscapeTimingClass.short => MindscapeLineTransition.fast,
    MindscapeTimingClass.normal => MindscapeLineTransition.normal,
  };
  final MindscapeWordReveal reveal = switch (cls) {
    MindscapeTimingClass.micro => MindscapeWordReveal.instant,
    MindscapeTimingClass.short => MindscapeWordReveal.fast,
    MindscapeTimingClass.normal => MindscapeWordReveal.normal,
  };
  final MindscapeTransitionTiming transition = mindscapeTransitionTiming(
    rawDuration,
    transitionMode,
    reveal,
  );
  final double lastEnd = lastWordEndTime ?? endTime;
  double renderEnd;
  if (transitionMode == MindscapeLineTransition.none) {
    renderEnd = math.max(endTime, startTime + _microLineRenderFloor);
  } else {
    final double passStart =
        math.max(lastEnd, startTime) + transition.linePassHold;
    final double exitStart = transitionMode == MindscapeLineTransition.fast
        ? math.max(
            math.max(startTime + transition.enterDuration + 0.01, passStart),
            endTime - transition.exitDuration,
          )
        : math.max(passStart, endTime - transition.exitDuration);
    renderEnd = math.max(endTime, exitStart + transition.exitDuration);
  }
  return MindscapeLineTiming(
    startTime: startTime,
    endTime: endTime,
    timingClass: cls,
    lineTransition: transitionMode,
    wordReveal: reveal,
    lineRenderEndTime: renderEnd,
    lastWordEndTime: lastEnd,
    transition: transition,
  );
}

MindscapeWordStatus mindscapeWordStatus(
  double time,
  MindscapeLineTiming line,
  MindscapeWordTime word,
) {
  final double lookahead = switch (line.wordReveal) {
    MindscapeWordReveal.fast => 0.045,
    MindscapeWordReveal.instant => 0,
    MindscapeWordReveal.normal => 0.18,
  };
  final double activeEnd = line.wordReveal == MindscapeWordReveal.instant
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
  MindscapeWordReveal reveal,
  MindscapeWordTime word,
) {
  if (reveal == MindscapeWordReveal.instant) {
    return time < word.startTime ? 0 : 1;
  }
  final double minDuration = reveal == MindscapeWordReveal.fast ? 0.045 : 0.01;
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
  if (line.wordReveal == MindscapeWordReveal.instant) {
    if (time < word.startTime || time > line.lineRenderEndTime) return 0;
    return _keyframedGlow(
      mindscapeClamp((time - word.startTime) / 0.067, 0, 1),
    );
  }
  if (line.wordReveal == MindscapeWordReveal.fast) {
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
  if (line.wordReveal == MindscapeWordReveal.instant) {
    if (time < word.startTime) return 0;
    return time <= line.lineRenderEndTime ? 1 : 0;
  }
  if (time < word.startTime) return 0;
  if (time <= word.endTime) {
    return mindscapeWordProgress(time, line.wordReveal, word);
  }
  final double fade = mindscapeClamp(
    (time - word.endTime) /
        (line.wordReveal == MindscapeWordReveal.fast ? 0.12 : 0.8),
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
    case MindscapeLineTransition.none:
      return MindscapeLineEnvelope.identity;
    case MindscapeLineTransition.fast:
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
    case MindscapeLineTransition.normal:
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
