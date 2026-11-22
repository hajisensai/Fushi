/// 云阶（folia partita）的时序：行级 render profile（folia `renderHints.ts` +
/// `glowWordTiming.ts`）、词 / 行的 waiting → active → passed 三态，以及把 framer-motion 的
/// spring / tween 过渡改写成「距状态切换多久」的解析函数，这样拖进度、倒放都能直接按时间算出姿态。
///
/// 时间一律是歌词显示毫秒（folia 用秒）。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';

/// 整行容器的进出场方式（folia `LineTransitionMode`）。
enum PartitaLineTransition { normal, fast, none }

/// 词高亮方式（folia `WordRevealMode`）。
enum PartitaWordReveal { normal, fast, instant }

/// 一行的渲染参数（folia `GlowWordRenderProfile`）。
@immutable
class PartitaRenderProfile {
  const PartitaRenderProfile({
    required this.renderEndMs,
    required this.transition,
    required this.reveal,
    required this.lookaheadMs,
  });

  /// 整行最多占到的视觉时间（folia `getLineRenderEndTime`）。
  final int renderEndMs;
  final PartitaLineTransition transition;
  final PartitaWordReveal reveal;

  /// 词提前进入 active 的预读量。
  final int lookaheadMs;

  /// 行离场时长（folia `getGlowWordLineContainerMotion` 的 exit）。
  int get exitMs => switch (transition) {
    PartitaLineTransition.normal => 300,
    PartitaLineTransition.fast => 160,
    PartitaLineTransition.none => 120,
  };
}

const double _microLineSeconds = 0.10;
const double _shortLineSeconds = 0.18;
const double _microLineRenderFloor = 0.067;

double _clampD(double v, double lo, double hi) => math.min(math.max(v, lo), hi);

/// 按行时长分档并算出 render end（folia `buildLineRenderHints`）。
PartitaRenderProfile partitaRenderProfileOf(LyricVisualizerLine line) {
  final double start = line.startMs / 1000;
  final double end = line.endMs / 1000;
  final double raw = math.max(end - start, 0);
  final PartitaLineTransition transition = raw < _microLineSeconds
      ? PartitaLineTransition.none
      : raw < _shortLineSeconds
      ? PartitaLineTransition.fast
      : PartitaLineTransition.normal;
  final PartitaWordReveal reveal = switch (transition) {
    PartitaLineTransition.none => PartitaWordReveal.instant,
    PartitaLineTransition.fast => PartitaWordReveal.fast,
    PartitaLineTransition.normal => PartitaWordReveal.normal,
  };
  final double lastWordEnd = line.words.isEmpty
      ? end
      : line.words.last.endMs / 1000;

  double renderEnd;
  if (transition == PartitaLineTransition.none) {
    renderEnd = math.max(end, start + _microLineRenderFloor);
  } else {
    final double enter;
    final double exit;
    final double hold;
    if (transition == PartitaLineTransition.fast) {
      enter = _clampD(raw * 0.45, 0.045, 0.06);
      exit = _clampD(raw * 0.22, 0.03, 0.04);
      hold = reveal == PartitaWordReveal.instant ? 0 : 0.03;
    } else {
      final double basis = math.max(raw, 0.12);
      enter = math.min(0.42, math.max(0.22, basis * 0.34));
      exit = math.min(0.32, math.max(0.18, basis * 0.18));
      hold = reveal == PartitaWordReveal.instant ? 0 : 0.06;
    }
    final double passStart = math.max(lastWordEnd, start) + hold;
    final double exitStart = transition == PartitaLineTransition.fast
        ? math.max(math.max(start + enter + 0.01, passStart), end - exit)
        : math.max(passStart, end - exit);
    renderEnd = math.max(end, exitStart + exit);
  }

  return PartitaRenderProfile(
    renderEndMs: (renderEnd * 1000).round(),
    transition: transition,
    reveal: reveal,
    lookaheadMs: switch (reveal) {
      PartitaWordReveal.instant => 30,
      PartitaWordReveal.fast => 80,
      PartitaWordReveal.normal => 150,
    },
  );
}

/// 一个词（或一行 chunk 的最后一个词）active 的结束时刻（folia `getGlowWordActiveEndTime`）。
int partitaActiveEndMs(int startMs, int endMs, PartitaRenderProfile p) =>
    switch (p.reveal) {
      PartitaWordReveal.instant => p.renderEndMs,
      PartitaWordReveal.fast => math.min(
        p.renderEndMs,
        math.max(endMs, startMs + 120),
      ),
      PartitaWordReveal.normal => endMs,
    };

/// 词的显示时长（folia `getGlowWordDisplayDuration`），毫秒。
int partitaDisplayDurationMs(int startMs, int endMs, PartitaRenderProfile p) {
  final int min = switch (p.reveal) {
    PartitaWordReveal.instant => 80,
    PartitaWordReveal.fast => 120,
    PartitaWordReveal.normal => 100,
  };
  return math.max(partitaActiveEndMs(startMs, endMs, p) - startMs, min);
}

/// 三态。
enum PartitaPhase { waiting, active, passed }

/// 一个元素（词或 chunk）在时间轴上的状态切换点。
@immutable
class PartitaStateTimes {
  const PartitaStateTimes({required this.activeAtMs, required this.passedAtMs});

  /// 由词起止 + 行起点推出：开始 = 起唱 − 预读（但不早于行出现），结束 = active end。
  factory PartitaStateTimes.of({
    required int startMs,
    required int activeEndMs,
    required int lineStartMs,
    required PartitaRenderProfile profile,
  }) {
    final int activeAt = math.max(startMs - profile.lookaheadMs, lineStartMs);
    return PartitaStateTimes(
      activeAtMs: activeAt,
      passedAtMs: math.max(activeEndMs, activeAt),
    );
  }

  final int activeAtMs;
  final int passedAtMs;

  /// folia：`t >= start - lookahead && t <= activeEnd` 为 active，之后为 passed。
  PartitaPhase phaseAt(int timeMs) => timeMs < activeAtMs
      ? PartitaPhase.waiting
      : timeMs <= passedAtMs
      ? PartitaPhase.active
      : PartitaPhase.passed;

  /// 进入 active 后经过的秒数。
  double sinceActive(int timeMs) => math.max(0, timeMs - activeAtMs) / 1000;

  /// 进入 passed 后经过的秒数。
  double sincePassed(int timeMs) => math.max(0, timeMs - passedAtMs) / 1000;
}

/// framer-motion spring（质量 1，初速 0）从 0 走到 1 的位移；[t] 秒。
double partitaSpring(double t, {double stiffness = 200, double damping = 20}) {
  if (t <= 0) return 0;
  final double w0 = math.sqrt(stiffness);
  final double zeta = damping / (2 * w0);
  if (zeta < 1) {
    final double wd = w0 * math.sqrt(1 - zeta * zeta);
    final double env = math.exp(-zeta * w0 * t);
    return 1 - env * (math.cos(wd * t) + (zeta * w0 / wd) * math.sin(wd * t));
  }
  // 临界 / 过阻尼（本样式用不到，保底）。
  return 1 - math.exp(-w0 * t) * (1 + w0 * t);
}

/// framer 的 easeInOut / easeOut（三次贝塞尔）。
const Cubic partitaEaseInOut = Cubic(0.42, 0, 0.58, 1);
const Cubic partitaEaseOut = Cubic(0, 0, 0.58, 1);

/// [t] 秒处一段 [duration] 秒的 tween 进度（带缓动）。
double partitaTween(
  double t,
  double duration, [
  Curve curve = partitaEaseInOut,
]) {
  if (duration <= 0) return 1;
  final double p = (t / duration).clamp(0.0, 1.0);
  return curve.transform(p);
}

/// framer keyframes：[values] 落在 [times]（0–1），每段用 [curve]；[t] 是相对开始的秒数。
double partitaKeyframes(
  double t,
  double duration,
  List<double> values,
  List<double> times, [
  Curve curve = partitaEaseInOut,
]) {
  if (t <= 0 || duration <= 0) return t <= 0 ? values.first : values.last;
  final double p = t / duration;
  if (p >= 1) return values.last;
  for (int i = 1; i < times.length; i++) {
    if (p <= times[i]) {
      final double span = times[i] - times[i - 1];
      final double local = span <= 0 ? 1 : (p - times[i - 1]) / span;
      return values[i - 1] +
          (values[i] - values[i - 1]) * curve.transform(local.clamp(0.0, 1.0));
    }
  }
  return values.last;
}
