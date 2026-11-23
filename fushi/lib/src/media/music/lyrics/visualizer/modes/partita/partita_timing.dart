/// 云阶（folia partita）的时序：行级渲染提示读共享的 `LyricVisualizerRenderHints`（folia
/// `renderHints.ts` + `glowWordTiming.ts`），这里是词 / 行的 waiting → active → passed 三态，以及把 framer-motion 的
/// spring / tween 过渡改写成「距状态切换多久」的解析函数，这样拖进度、倒放都能直接按时间算出姿态。
///
/// 时间一律是歌词显示毫秒（folia 用秒）。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_render_hints.dart';
export 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_render_hints.dart'
    show
        LyricVisualizerLineTransition,
        LyricVisualizerRenderHints,
        LyricVisualizerWordReveal;

/// 整句容器的离场时长（folia `getGlowWordLineContainerMotion` 的 exit；与共享 renderHints 的
/// `exitMs`（句尾离场窗口）不是一回事）。
int partitaLineExitMs(LyricVisualizerLineTransition transition) =>
    switch (transition) {
      LyricVisualizerLineTransition.normal => 300,
      LyricVisualizerLineTransition.fast => 160,
      LyricVisualizerLineTransition.none => 120,
    };

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
    required LyricVisualizerRenderHints profile,
  }) {
    final int activeAt = math.max(
      startMs - profile.wordLookaheadMs,
      lineStartMs,
    );
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
