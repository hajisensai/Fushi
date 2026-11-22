/// 行的渲染提示（folia `src/utils/lyrics/renderHints.ts` 逐条移植）：按行时长分 micro / short /
/// normal 三档，决定行过渡（无 / 快 / 正常）、逐词显现（瞬显 / 快 / 正常），并算出句尾离场窗口
/// `renderEndMs`（这一行最晚可以留在屏上的时刻）。
///
/// folia 的时间是秒，这里一律毫秒；内部按秒的同一公式算，结果四舍五入成整数毫秒。原先流光 / 云阶 /
/// 心象 / 群唱各自带了一份本地移植，语义与这里一致（流光 `LuminousRenderProfile` 是逐字同一公式）。
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show immutable;

/// 行时长分级（folia `LineTimingClass`）。
enum LyricVisualizerTimingClass { normal, short, micro }

/// 行过渡（folia `LineTransitionMode`）。
enum LyricVisualizerLineTransition { normal, fast, none }

/// 逐词显现（folia `WordRevealMode`）。
enum LyricVisualizerWordReveal { normal, fast, instant }

/// folia `MICRO_LINE_DURATION_THRESHOLD` 等（秒）。
const double _microThresholdS = 0.10;
const double _shortThresholdS = 0.18;
const double _microRenderFloorS = 0.067;

double _clamp(double v, double lo, double hi) => math.min(math.max(v, lo), hi);

/// 一行的渲染提示。
@immutable
class LyricVisualizerRenderHints {
  const LyricVisualizerRenderHints({
    required this.rawDurationMs,
    required this.timingClass,
    required this.renderEndMs,
    required this.lineTransition,
    required this.wordReveal,
    required this.enterMs,
    required this.exitMs,
    required this.passHoldMs,
  });

  /// folia `buildLineRenderHints`。[lastWordEndMs] 是最后一个词的结束（没有词传行尾）。
  factory LyricVisualizerRenderHints.of({
    required int startMs,
    required int endMs,
    int? lastWordEndMs,
  }) {
    final double startS = startMs / 1000;
    final double endS = endMs / 1000;
    final double lastWordEndS = (lastWordEndMs ?? endMs) / 1000;
    final double raw = math.max(endS - startS, 0);
    final LyricVisualizerTimingClass cls = raw < _microThresholdS
        ? LyricVisualizerTimingClass.micro
        : raw < _shortThresholdS
        ? LyricVisualizerTimingClass.short
        : LyricVisualizerTimingClass.normal;
    final LyricVisualizerLineTransition transition = switch (cls) {
      LyricVisualizerTimingClass.micro => LyricVisualizerLineTransition.none,
      LyricVisualizerTimingClass.short => LyricVisualizerLineTransition.fast,
      LyricVisualizerTimingClass.normal => LyricVisualizerLineTransition.normal,
    };
    final LyricVisualizerWordReveal reveal = switch (cls) {
      LyricVisualizerTimingClass.micro => LyricVisualizerWordReveal.instant,
      LyricVisualizerTimingClass.short => LyricVisualizerWordReveal.fast,
      LyricVisualizerTimingClass.normal => LyricVisualizerWordReveal.normal,
    };
    final (double enter, double exit, double hold) = lineTransitionTiming(
      raw,
      transition,
      reveal,
    );
    double renderEnd;
    if (transition == LyricVisualizerLineTransition.none) {
      renderEnd = math.max(endS, startS + _microRenderFloorS);
    } else {
      final double passStart = math.max(lastWordEndS, startS) + hold;
      final double exitStart = transition == LyricVisualizerLineTransition.fast
          ? math.max(math.max(startS + enter + 0.01, passStart), endS - exit)
          : math.max(passStart, endS - exit);
      renderEnd = math.max(endS, exitStart + exit);
    }
    return LyricVisualizerRenderHints(
      rawDurationMs: math.max(endMs - startMs, 0),
      timingClass: cls,
      renderEndMs: (renderEnd * 1000).round(),
      lineTransition: transition,
      wordReveal: reveal,
      enterMs: (enter * 1000).round(),
      exitMs: (exit * 1000).round(),
      passHoldMs: (hold * 1000).round(),
    );
  }

  /// folia `getLineTransitionTiming`（秒）：(enter, exit, linePassHold)。
  static (double, double, double) lineTransitionTiming(
    double rawDurationS,
    LyricVisualizerLineTransition transition,
    LyricVisualizerWordReveal reveal,
  ) {
    switch (transition) {
      case LyricVisualizerLineTransition.none:
        return (0, 0, 0);
      case LyricVisualizerLineTransition.fast:
        return (
          _clamp(rawDurationS * 0.45, 0.045, 0.06),
          _clamp(rawDurationS * 0.22, 0.03, 0.04),
          reveal == LyricVisualizerWordReveal.instant ? 0 : 0.03,
        );
      case LyricVisualizerLineTransition.normal:
        final double d = math.max(rawDurationS, 0.12);
        return (
          math.min(0.42, math.max(0.22, d * 0.34)),
          math.min(0.32, math.max(0.18, d * 0.18)),
          reveal == LyricVisualizerWordReveal.instant ? 0 : 0.06,
        );
    }
  }

  final int rawDurationMs;
  final LyricVisualizerTimingClass timingClass;

  /// 这一行最晚可以留在屏上的时刻（含句尾离场窗口）。不保证独占：下一行可能更早开始，样式据此截短。
  final int renderEndMs;
  final LyricVisualizerLineTransition lineTransition;
  final LyricVisualizerWordReveal wordReveal;

  /// 行入场 / 离场时长、唱完后的停留（folia `LineTransitionTiming`）。
  final int enterMs;
  final int exitMs;
  final int passHoldMs;

  /// 词提前多少毫秒进入 active（folia `glowWordTiming` 的 lookahead：瞬显 30 / 快 80 / 正常 150）。
  int get wordLookaheadMs => switch (wordReveal) {
    LyricVisualizerWordReveal.instant => 30,
    LyricVisualizerWordReveal.fast => 80,
    LyricVisualizerWordReveal.normal => 150,
  };

  /// 词的 active 结束时刻（folia `getGlowWordActiveEndTime`）：瞬显到整行离场、快显至少 120ms。
  int wordActiveEndMs(int wordStartMs, int wordEndMs) => switch (wordReveal) {
    LyricVisualizerWordReveal.instant => renderEndMs,
    LyricVisualizerWordReveal.fast => math.min(
      renderEndMs,
      math.max(wordEndMs, wordStartMs + 120),
    ),
    LyricVisualizerWordReveal.normal => wordEndMs,
  };

  /// 词的显示时长（folia `getGlowWordDisplayDuration`）。
  int wordDisplayDurationMs(int wordStartMs, int wordEndMs) {
    final int minD = switch (wordReveal) {
      LyricVisualizerWordReveal.instant => 80,
      LyricVisualizerWordReveal.fast => 120,
      LyricVisualizerWordReveal.normal => 100,
    };
    return math.max(
      wordActiveEndMs(wordStartMs, wordEndMs) - wordStartMs,
      minD,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LyricVisualizerRenderHints &&
      other.rawDurationMs == rawDurationMs &&
      other.timingClass == timingClass &&
      other.renderEndMs == renderEndMs &&
      other.lineTransition == lineTransition &&
      other.wordReveal == wordReveal &&
      other.enterMs == enterMs &&
      other.exitMs == exitMs &&
      other.passHoldMs == passHoldMs;

  @override
  int get hashCode => Object.hash(
    rawDurationMs,
    timingClass,
    renderEndMs,
    lineTransition,
    wordReveal,
    enterMs,
    exitMs,
    passHoldMs,
  );
}
