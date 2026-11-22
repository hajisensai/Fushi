/// 流光的时序：把 folia 的 renderHints / glowWordTiming / glowWordVariants / wordGlow 换成
/// 「给定时刻 → 动画值」的纯函数。folia 用 framer-motion 在状态切换时起动画；这里按时间
/// 解析地算出同一条曲线（弹簧闭式解 + 缓动关键帧），拖进度、暂停都能直接求值，不存动画状态。
///
/// 时间单位统一为秒（与 folia 一致），调用方把歌词显示毫秒除以 1000 传进来。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';

/// 行过渡模式（folia `LineTransitionMode`）。
enum LuminousLineTransition { normal, fast, none }

/// 逐词显现模式（folia `WordRevealMode`）。
enum LuminousWordReveal { normal, fast, instant }

/// 动画强度（folia `theme.animationIntensity`）。
enum LuminousIntensity { calm, normal, chaotic }

/// framer-motion 的 easeOut / easeInOut。
const Cubic luminousEaseOut = Cubic(0.0, 0.0, 0.58, 1.0);
const Cubic luminousEaseInOut = Cubic(0.42, 0.0, 0.58, 1.0);

const double _microLineThreshold = 0.10;
const double _shortLineThreshold = 0.18;
const double _microLineRenderFloor = 0.067;

double _clampD(double v, double lo, double hi) => math.min(math.max(v, lo), hi);

/// 一行的渲染提示（folia `buildLineRenderHints` + `resolveGlowWordRenderProfile`）。
@immutable
class LuminousRenderProfile {
  const LuminousRenderProfile({
    required this.lineTransition,
    required this.wordReveal,
    required this.lineRenderEnd,
    required this.wordLookahead,
  });

  /// [startS] / [endS] 是行起止，[lastWordEndS] 是最后一个词的结束（秒）。
  factory LuminousRenderProfile.fromTimes({
    required double startS,
    required double endS,
    required double lastWordEndS,
  }) {
    final double raw = math.max(endS - startS, 0);
    final LuminousLineTransition transition = raw < _microLineThreshold
        ? LuminousLineTransition.none
        : raw < _shortLineThreshold
        ? LuminousLineTransition.fast
        : LuminousLineTransition.normal;
    final LuminousWordReveal reveal = raw < _microLineThreshold
        ? LuminousWordReveal.instant
        : raw < _shortLineThreshold
        ? LuminousWordReveal.fast
        : LuminousWordReveal.normal;
    double renderEnd;
    if (transition == LuminousLineTransition.none) {
      renderEnd = math.max(endS, startS + _microLineRenderFloor);
    } else {
      final double enter;
      final double exit;
      final double hold;
      if (transition == LuminousLineTransition.fast) {
        enter = _clampD(raw * 0.45, 0.045, 0.06);
        exit = _clampD(raw * 0.22, 0.03, 0.04);
        hold = reveal == LuminousWordReveal.instant ? 0 : 0.03;
      } else {
        enter = math.min(0.42, math.max(0.22, math.max(raw, 0.12) * 0.34));
        exit = math.min(0.32, math.max(0.18, math.max(raw, 0.12) * 0.18));
        hold = reveal == LuminousWordReveal.instant ? 0 : 0.06;
      }
      final double passStart = math.max(lastWordEndS, startS) + hold;
      final double exitStart = transition == LuminousLineTransition.fast
          ? math.max(math.max(startS + enter + 0.01, passStart), endS - exit)
          : math.max(passStart, endS - exit);
      renderEnd = math.max(endS, exitStart + exit);
    }
    return LuminousRenderProfile(
      lineTransition: transition,
      wordReveal: reveal,
      lineRenderEnd: renderEnd,
      wordLookahead: reveal == LuminousWordReveal.instant
          ? 0.03
          : reveal == LuminousWordReveal.fast
          ? 0.08
          : 0.15,
    );
  }

  factory LuminousRenderProfile.ofLine(LyricVisualizerLine line) =>
      LuminousRenderProfile.fromTimes(
        startS: line.startMs / 1000,
        endS: line.endMs / 1000,
        lastWordEndS: line.words.isEmpty
            ? line.endMs / 1000
            : line.words.last.endMs / 1000,
      );

  final LuminousLineTransition lineTransition;
  final LuminousWordReveal wordReveal;

  /// 这一行最晚可以留在屏上的时刻（秒）。
  final double lineRenderEnd;

  /// 词提前多少秒进入 active。
  final double wordLookahead;

  /// 词的 active 结束时刻（folia `getGlowWordActiveEndTime`）。
  double activeEnd(double wordStart, double wordEnd) {
    switch (wordReveal) {
      case LuminousWordReveal.instant:
        return lineRenderEnd;
      case LuminousWordReveal.fast:
        return math.min(lineRenderEnd, math.max(wordEnd, wordStart + 0.12));
      case LuminousWordReveal.normal:
        return wordEnd;
    }
  }

  /// 词的显示时长（folia `getGlowWordDisplayDuration`）。
  double displayDuration(double wordStart, double wordEnd) {
    final double minD = wordReveal == LuminousWordReveal.instant
        ? 0.08
        : wordReveal == LuminousWordReveal.fast
        ? 0.12
        : 0.1;
    return math.max(activeEnd(wordStart, wordEnd) - wordStart, minD);
  }
}

// ---------------------------------------------------------------------------
// 曲线工具
// ---------------------------------------------------------------------------

/// framer 的 spring（stiffness 200, damping 20, mass 1，初速 0）从 0 走到 1 的进度。
/// ζ = 0.707、ω0 = √200，闭式解 1 − e^(−ζω0·t)(cos ωd·t + ζω0/ωd · sin ωd·t)。
double luminousSpring(double t, {double stiffness = 200, double damping = 20}) {
  if (t <= 0) return 0;
  final double w0 = math.sqrt(stiffness);
  final double zeta = damping / (2 * w0);
  if (zeta >= 1) {
    // 临界 / 过阻尼：用临界阻尼近似（这里用不到，留作兜底）。
    return 1 - math.exp(-w0 * t) * (1 + w0 * t);
  }
  final double wd = w0 * math.sqrt(1 - zeta * zeta);
  final double a = zeta * w0;
  return 1 - math.exp(-a * t) * (math.cos(wd * t) + a / wd * math.sin(wd * t));
}

/// 时长 [duration] 的补间进度（0–1），[curve] 作用在线性进度上。
double luminousTween(double t, double duration, Curve curve) {
  if (t <= 0) return 0;
  if (duration <= 0 || t >= duration) return 1;
  return curve.transform(t / duration);
}

/// framer 关键帧：[values] 在 [times]（0–1）处，每段都套 [curve]。
double luminousKeyframes(
  double t,
  double duration,
  List<double> values,
  List<double> times,
  Curve curve,
) {
  if (t <= 0 || duration <= 0) return t <= 0 ? values.first : values.last;
  final double p = t / duration;
  if (p >= 1) return values.last;
  for (int i = 1; i < times.length; i++) {
    if (p <= times[i]) {
      final double span = times[i] - times[i - 1];
      final double local = span <= 0 ? 1 : (p - times[i - 1]) / span;
      return _lerp(values[i - 1], values[i], curve.transform(local));
    }
  }
  return values.last;
}

double _lerp(double a, double b, double t) => a + (b - a) * t;

// ---------------------------------------------------------------------------
// 词的三态（waiting → active → passed）
// ---------------------------------------------------------------------------

/// 一个词在布局里的随机姿态（folia `WordLayoutConfig`）。
@immutable
class LuminousWordConfig {
  const LuminousWordConfig({
    required this.x,
    required this.y,
    required this.rotate,
    required this.scale,
    required this.passedRotate,
  });

  final double x;
  final double y;

  /// 度。
  final double rotate;
  final double scale;

  /// passed 后 5 秒内再转过的角度（度）。
  final double passedRotate;
}

/// 词容器此刻的变换与不透明度。
@immutable
class LuminousWordPose {
  const LuminousWordPose({
    required this.opacity,
    required this.scale,
    required this.x,
    required this.y,
    required this.rotate,
  });

  final double opacity;
  final double scale;
  final double x;
  final double y;

  /// 度。
  final double rotate;

  static LuminousWordPose lerp(
    LuminousWordPose a,
    LuminousWordPose b,
    double tPos,
    double tOpacity,
    double tRotate,
  ) => LuminousWordPose(
    opacity: _lerp(a.opacity, b.opacity, tOpacity),
    scale: _lerp(a.scale, b.scale, tPos),
    x: _lerp(a.x, b.x, tPos),
    y: _lerp(a.y, b.y, tPos),
    rotate: _lerp(a.rotate, b.rotate, tRotate),
  );
}

/// 词进入 active 时的放大倍数（folia `GLOW_WORD_ACTIVE_SCALE`）。
const double luminousActiveScale = 1.4;

/// waiting 姿态：在偏离位置缩小透明待命（folia `buildGlowWordLayoutVariants.waiting`）。
LuminousWordPose luminousWaitingPose(LuminousWordConfig c, bool rotation) =>
    LuminousWordPose(
      opacity: 0,
      scale: 0.5,
      x: c.x + math.sin(c.y) * 100,
      y: c.y + math.cos(c.x) * 50,
      rotate: rotation ? c.rotate + 20 : 0,
    );

LuminousWordPose luminousActivePose(LuminousWordConfig c) => LuminousWordPose(
  opacity: 1,
  scale: c.scale.isNaN ? 1.5 : c.scale * luminousActiveScale,
  x: c.x,
  y: c.y,
  rotate: c.rotate,
);

LuminousWordPose luminousPassedPose(
  LuminousWordConfig c,
  LuminousIntensity intensity,
) => LuminousWordPose(
  opacity: intensity == LuminousIntensity.chaotic ? 0.9 : 0.82,
  scale: c.scale == 0 ? 1 : c.scale,
  x: c.x,
  y: c.y,
  rotate: c.rotate + c.passedRotate,
);

/// 一个词的时刻表（秒）：何时进入 active、何时转 passed。
@immutable
class LuminousWordSchedule {
  const LuminousWordSchedule({
    required this.activeAt,
    required this.passedAt,
    required this.wordStart,
    required this.duration,
  });

  /// [mountAt] = 行挂上的时刻（行起点）：folia 的词在行挂载后才开始监听时间。
  factory LuminousWordSchedule.of({
    required LuminousRenderProfile profile,
    required double wordStart,
    required double wordEnd,
    required double mountAt,
  }) {
    final double activeEnd = profile.activeEnd(wordStart, wordEnd);
    return LuminousWordSchedule(
      activeAt: math.max(mountAt, wordStart - profile.wordLookahead),
      passedAt: math.max(mountAt, activeEnd),
      wordStart: wordStart,
      duration: profile.displayDuration(wordStart, wordEnd),
    );
  }

  final double activeAt;

  /// active 区间是闭区间 [activeAt, passedAt]，之后 passed。
  final double passedAt;
  final double wordStart;
  final double duration;

  LuminousWordState stateAt(double t) {
    if (t > passedAt) return LuminousWordState.passed;
    if (t >= activeAt) return LuminousWordState.active;
    return LuminousWordState.waiting;
  }
}

enum LuminousWordState { waiting, active, passed }

/// 词容器在 [t] 时的姿态：waiting→active 走弹簧（不透明度 0.1 秒），
/// active→passed 0.5 秒 easeOut、旋转 5 秒线性（folia layout variants）。
LuminousWordPose luminousWordPoseAt({
  required double t,
  required LuminousWordSchedule schedule,
  required LuminousWordConfig config,
  required bool rotation,
  required LuminousIntensity intensity,
}) {
  final LuminousWordPose waiting = luminousWaitingPose(config, rotation);
  final LuminousWordPose active = luminousActivePose(config);
  LuminousWordPose activeAtTime(double at) {
    final double dt = at - schedule.activeAt;
    final double s = luminousSpring(dt);
    return LuminousWordPose.lerp(
      waiting,
      active,
      s,
      luminousTween(dt, 0.1, luminousEaseOut),
      s,
    );
  }

  final LuminousWordState state = schedule.stateAt(t);
  switch (state) {
    case LuminousWordState.waiting:
      return waiting;
    case LuminousWordState.active:
      return activeAtTime(t);
    case LuminousWordState.passed:
      // active 区间为空（挂上时已唱完）时从 waiting 直接过渡。
      final LuminousWordPose from = schedule.passedAt >= schedule.activeAt
          ? activeAtTime(schedule.passedAt)
          : waiting;
      final double dt = t - schedule.passedAt;
      final double p = luminousTween(dt, 0.5, luminousEaseOut);
      return LuminousWordPose.lerp(
        from,
        luminousPassedPose(config, intensity),
        p,
        p,
        luminousTween(dt, 5, Curves.linear),
      );
  }
}

/// 正文层：颜色进度（0 = 底色，1 = 高亮色）与模糊（CSS px）。
@immutable
class LuminousBodyState {
  const LuminousBodyState({required this.highlight, required this.blur});

  final double highlight;
  final double blur;
}

/// folia `glowWordBodyVariants`：active 时底色→高亮色按词时长线性走，模糊 10px→0；
/// passed 时高亮色→底色（normal 0.8 秒 easeInOut）。
LuminousBodyState luminousBodyAt({
  required double t,
  required LuminousWordSchedule schedule,
  required LuminousWordReveal reveal,
}) {
  final double blurIn = reveal == LuminousWordReveal.instant
      ? 0.08
      : reveal == LuminousWordReveal.fast
      ? 0.12
      : 0.2;
  double highlightAtActive(double at) {
    final double dt = at - schedule.activeAt;
    final double d = schedule.duration <= 0 ? 0.2 : schedule.duration;
    return luminousTween(dt, d, Curves.linear);
  }

  switch (schedule.stateAt(t)) {
    case LuminousWordState.waiting:
      return const LuminousBodyState(highlight: 0, blur: 10);
    case LuminousWordState.active:
      final double dt = t - schedule.activeAt;
      return LuminousBodyState(
        highlight: highlightAtActive(t),
        blur: 10 * (1 - luminousTween(dt, blurIn, luminousEaseOut)),
      );
    case LuminousWordState.passed:
      final double from = schedule.passedAt >= schedule.activeAt
          ? highlightAtActive(schedule.passedAt)
          : 0;
      final double back = reveal == LuminousWordReveal.instant
          ? 0.12
          : reveal == LuminousWordReveal.fast
          ? 0.24
          : 0.8;
      final double p = luminousTween(
        t - schedule.passedAt,
        back,
        luminousEaseInOut,
      );
      return LuminousBodyState(highlight: from * (1 - p), blur: 0);
  }
}

/// 发光光晕的两档半径（CSS text-shadow px）：[inner, outer]（folia `glowRadii`）。
(double, double) luminousGlowRadii(LuminousWordReveal reveal) =>
    switch (reveal) {
      LuminousWordReveal.instant => (14, 24),
      LuminousWordReveal.fast => (18, 32),
      LuminousWordReveal.normal => (20, 40),
    };

/// 单个字形光晕的不透明度（folia `wordGlowVariants`）。[glyphIndex] / [glyphCount] 指字形在词
/// 里的序号；[charStart] / [charEnd] 是字形自己的时间（秒）。
double luminousGlowAt({
  required double t,
  required LuminousWordSchedule schedule,
  required LuminousWordReveal reveal,
  required int glyphCount,
  double? charStart,
  double? charEnd,
  int glyphIndex = 0,
}) {
  double activeRamp(double at) {
    final double dt = at - schedule.activeAt;
    switch (reveal) {
      case LuminousWordReveal.instant:
        return luminousKeyframes(
          dt,
          math.min(schedule.duration, 0.12),
          const <double>[0, 1, 0],
          const <double>[0, 0.35, 1],
          luminousEaseOut,
        );
      case LuminousWordReveal.fast:
        return luminousKeyframes(
          dt,
          _clampD(schedule.duration, 0.12, 0.2),
          const <double>[0, 1, 0],
          const <double>[0, 0.4, 1],
          luminousEaseInOut,
        );
      case LuminousWordReveal.normal:
        if (glyphCount > 1) {
          // 逐字母扫光：每个字形按自己的起点延迟，持续 6 个字长，早到峰值再淡出。
          final double single = schedule.duration / glyphCount;
          final bool timed = charStart != null && charEnd != null;
          final double charDur = timed
              ? math.max(charEnd - charStart, 0.001)
              : single;
          final double delay = timed
              ? math.max(0, charStart - schedule.wordStart)
              : single * glyphIndex;
          return luminousKeyframes(
            dt - delay,
            charDur * 6,
            const <double>[0, 1, 0],
            const <double>[0, 0.3, 1],
            luminousEaseInOut,
          );
        }
        // 单字 / CJK：持续发光到词尾。
        return luminousKeyframes(
          dt,
          schedule.duration,
          const <double>[0, 1, 1],
          const <double>[0, 0.9, 1],
          luminousEaseInOut,
        );
    }
  }

  switch (schedule.stateAt(t)) {
    case LuminousWordState.waiting:
      return 0;
    case LuminousWordState.active:
      return activeRamp(t);
    case LuminousWordState.passed:
      final double from = schedule.passedAt >= schedule.activeAt
          ? activeRamp(schedule.passedAt)
          : 0;
      final double fade = reveal == LuminousWordReveal.instant
          ? 0.12
          : reveal == LuminousWordReveal.fast
          ? 0.22
          : 0.9;
      return from *
          (1 - luminousTween(t - schedule.passedAt, fade, luminousEaseOut));
  }
}

// ---------------------------------------------------------------------------
// 整行容器的入场 / 离场（folia `getGlowWordLineContainerMotion`）
// ---------------------------------------------------------------------------

/// 整行容器此刻的不透明度、缩放与模糊（CSS px）。
@immutable
class LuminousLineFx {
  const LuminousLineFx({
    required this.opacity,
    required this.scale,
    required this.blur,
  });

  static const LuminousLineFx steady = LuminousLineFx(
    opacity: 1,
    scale: 1,
    blur: 0,
  );

  final double opacity;
  final double scale;
  final double blur;

  bool get isSteady =>
      opacity >= 0.999 && (scale - 1).abs() < 1e-4 && blur < 0.05;
}

/// 离场时长（秒）。
double luminousLineExitDuration(LuminousLineTransition mode) => switch (mode) {
  LuminousLineTransition.none => 0.12,
  LuminousLineTransition.fast => 0.16,
  LuminousLineTransition.normal => 0.3,
};

/// 入场：[sinceEnter] 是行挂上后经过的秒数。
LuminousLineFx luminousLineEnterFx(
  LuminousLineTransition mode,
  double sinceEnter,
) {
  switch (mode) {
    case LuminousLineTransition.none:
      return LuminousLineFx.steady;
    case LuminousLineTransition.fast:
      final double p = luminousTween(sinceEnter, 0.16, luminousEaseOut);
      return LuminousLineFx(
        opacity: _lerp(0.35, 1, p),
        scale: _lerp(0.96, 1, p),
        blur: _lerp(4, 0, p),
      );
    case LuminousLineTransition.normal:
      // framer 默认：不透明度 / 模糊 0.3 秒补间，缩放走默认弹簧（这里用同一弹簧）。
      final double p = luminousTween(sinceEnter, 0.3, luminousEaseOut);
      final double s = luminousSpring(sinceEnter, stiffness: 100, damping: 20);
      return LuminousLineFx(
        opacity: p,
        scale: _lerp(0.9, 1, s),
        blur: _lerp(10, 0, p),
      );
  }
}

/// 离场：[sinceExit] 是开始离场后经过的秒数。
LuminousLineFx luminousLineExitFx(
  LuminousLineTransition mode,
  double sinceExit,
) {
  final double d = luminousLineExitDuration(mode);
  switch (mode) {
    case LuminousLineTransition.none:
      final double p = luminousTween(sinceExit, d, luminousEaseOut);
      return LuminousLineFx(
        opacity: 1 - p,
        scale: _lerp(1, 1.02, p),
        blur: 6 * p,
      );
    case LuminousLineTransition.fast:
      final double p = luminousTween(sinceExit, d, luminousEaseInOut);
      return LuminousLineFx(
        opacity: 1 - p,
        scale: _lerp(1, 1.04, p),
        blur: 10 * p,
      );
    case LuminousLineTransition.normal:
      final double p = luminousTween(sinceExit, d, luminousEaseOut);
      return LuminousLineFx(
        opacity: 1 - p,
        scale: _lerp(1, 1.1, p),
        blur: 20 * p,
      );
  }
}

// ---------------------------------------------------------------------------
// 整片歌词的呼吸浮动
// ---------------------------------------------------------------------------

/// 呼吸浮动此刻的位移（px，向下为正）与缩放。
@immutable
class LuminousBreath {
  const LuminousBreath({required this.dy, required this.scale});

  static const LuminousBreath none = LuminousBreath(dy: 0, scale: 1);

  final double dy;
  final double scale;
}

/// folia `lyricContainerFloat`：y [0, −d, 0, 0.45d, 0]、scale [1, 1+0.01m, 1, 1−0.005m, 1]，
/// 每段 easeInOut 无限循环；距离 / 周期随强度。[elapsed] 是墙钟秒数。
LuminousBreath luminousBreathAt(
  double elapsed,
  double multiplier,
  LuminousIntensity intensity,
) {
  if (multiplier <= 0) return LuminousBreath.none;
  final (double distance, double period) = switch (intensity) {
    LuminousIntensity.calm => (10.0, 8.5),
    LuminousIntensity.normal => (14.0, 7.0),
    LuminousIntensity.chaotic => (18.0, 5.8),
  };
  final double d = distance * multiplier;
  final double local = elapsed % period;
  const List<double> times = <double>[0, 0.25, 0.5, 0.75, 1];
  return LuminousBreath(
    dy: luminousKeyframes(
      local,
      period,
      <double>[0, -d, 0, d * 0.45, 0],
      times,
      luminousEaseInOut,
    ),
    scale: luminousKeyframes(
      local,
      period,
      <double>[1, 1 + 0.01 * multiplier, 1, 1 - 0.005 * multiplier, 1],
      times,
      luminousEaseInOut,
    ),
  );
}
