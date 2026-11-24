/// 流光的时序：行分级与离场窗口读共享的 renderHints，把 folia 的 glowWordTiming / glowWordVariants / wordGlow 换成
/// 「给定时刻 → 动画值」的纯函数。folia 用 framer-motion 在状态切换时起动画；这里按时间
/// 解析地算出同一条曲线（弹簧闭式解 + 缓动关键帧），拖进度、暂停都能直接求值，不存动画状态。
///
/// 时间单位统一为秒（与 folia 一致），调用方把歌词显示毫秒除以 1000 传进来。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_theme.dart';

export 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_render_hints.dart'
    show
        LyricVisualizerLineTransition,
        LyricVisualizerRenderHints,
        LyricVisualizerWordReveal;
export 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_theme.dart'
    show LyricVisualizerIntensity;

/// framer-motion 的 easeOut / easeInOut。只写了 duration、没写 ease 的补间，framer 的 keyframes
/// 生成器默认就是 easeInOut。
const Cubic luminousEaseOut = Cubic(0.0, 0.0, 0.58, 1.0);
const Cubic luminousEaseInOut = Cubic(0.42, 0.0, 0.58, 1.0);

/// framer 对非变换属性（opacity / filter / color）在完全没写 transition 时的默认补间：
/// `cubic-bezier(0.25, 0.1, 0.35, 1)`，0.3 秒（motion-dom `getDefaultTransition`）。
const Cubic luminousEaseDefault = Cubic(0.25, 0.1, 0.35, 1.0);

/// framer 对 scale 在没写 transition 时的默认弹簧（`criticallyDampedSpring`，目标非 0）。
const double luminousDefaultScaleStiffness = 550;
const double luminousDefaultScaleDamping = 30;

/// framer 的颜色插值（`mixLinearColor`）：RGB 通道按平方插值再开方（不是 sRGB 直线插值），
/// alpha 线性。
Color luminousMixColor(Color from, Color to, double p) {
  double ch(double a, double b) {
    final double e = a * a + p * (b * b - a * a);
    return e <= 0 ? 0 : math.sqrt(e);
  }

  return Color.from(
    alpha: from.a + (to.a - from.a) * p,
    red: ch(from.r, to.r),
    green: ch(from.g, to.g),
    blue: ch(from.b, to.b),
  );
}

double _clampD(double v, double lo, double hi) => math.min(math.max(v, lo), hi);

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
  LyricVisualizerIntensity intensity,
) => LuminousWordPose(
  opacity: intensity == LyricVisualizerIntensity.chaotic ? 0.9 : 0.82,
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
    required LyricVisualizerRenderHints hints,
    required double wordStart,
    required double wordEnd,
    required double mountAt,
  }) {
    final int startMs = (wordStart * 1000).round();
    final int endMs = (wordEnd * 1000).round();
    final double activeEnd = hints.wordActiveEndMs(startMs, endMs) / 1000;
    return LuminousWordSchedule(
      activeAt: math.max(mountAt, wordStart - hints.wordLookaheadMs / 1000),
      passedAt: math.max(mountAt, activeEnd),
      wordStart: wordStart,
      duration: hints.wordDisplayDurationMs(startMs, endMs) / 1000,
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
  required LyricVisualizerIntensity intensity,
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
      // active 的 opacity 只写了 duration 0.1，framer 默认 easeInOut。
      luminousTween(dt, 0.1, luminousEaseInOut),
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
      // passed 只写了 duration 0.5（没写 ease）：framer 默认 easeInOut。
      final double p = luminousTween(dt, 0.5, luminousEaseInOut);
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
  required LyricVisualizerWordReveal reveal,
}) {
  final double blurIn = reveal == LyricVisualizerWordReveal.instant
      ? 0.08
      : reveal == LyricVisualizerWordReveal.fast
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
        // filter 是 `type: 'tween'` 只给时长：默认 easeInOut。
        blur: 10 * (1 - luminousTween(dt, blurIn, luminousEaseInOut)),
      );
    case LuminousWordState.passed:
      final double from = schedule.passedAt >= schedule.activeAt
          ? highlightAtActive(schedule.passedAt)
          : 0;
      final double back = reveal == LyricVisualizerWordReveal.instant
          ? 0.12
          : reveal == LyricVisualizerWordReveal.fast
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
(double, double) luminousGlowRadii(LyricVisualizerWordReveal reveal) =>
    switch (reveal) {
      LyricVisualizerWordReveal.instant => (14, 24),
      LyricVisualizerWordReveal.fast => (18, 32),
      LyricVisualizerWordReveal.normal => (20, 40),
    };

/// 单个字形光晕的不透明度（folia `wordGlowVariants`）。[glyphIndex] / [glyphCount] 指字形在词
/// 里的序号；[charStart] / [charEnd] 是字形自己的时间（秒）。
double luminousGlowAt({
  required double t,
  required LuminousWordSchedule schedule,
  required LyricVisualizerWordReveal reveal,
  required int glyphCount,
  double? charStart,
  double? charEnd,
  int glyphIndex = 0,
}) {
  double activeRamp(double at) {
    final double dt = at - schedule.activeAt;
    switch (reveal) {
      case LyricVisualizerWordReveal.instant:
        return luminousKeyframes(
          dt,
          math.min(schedule.duration, 0.12),
          const <double>[0, 1, 0],
          const <double>[0, 0.35, 1],
          luminousEaseOut,
        );
      case LyricVisualizerWordReveal.fast:
        return luminousKeyframes(
          dt,
          _clampD(schedule.duration, 0.12, 0.2),
          const <double>[0, 1, 0],
          const <double>[0, 0.4, 1],
          luminousEaseInOut,
        );
      case LyricVisualizerWordReveal.normal:
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
      final double fade = reveal == LyricVisualizerWordReveal.instant
          ? 0.12
          : reveal == LyricVisualizerWordReveal.fast
          ? 0.22
          : 0.9;
      return from *
          (1 - luminousTween(t - schedule.passedAt, fade, luminousEaseOut));
  }
}

// ---------------------------------------------------------------------------
// 副歌涟漪（folia `GlowWord` 的 Chorus Ripple）
// ---------------------------------------------------------------------------

/// 涟漪此刻的缩放与不透明度。
@immutable
class LuminousRipple {
  const LuminousRipple({required this.scale, required this.opacity});

  final double scale;
  final double opacity;
}

/// 涟漪扩到的倍数：folia `1.5 + Math.random() * 2`，按行起点 [seed]（秒）与词序确定性取。
double luminousRippleScale(double seed, int wordIndex) {
  final double x =
      math.sin(seed * 7.13 + wordIndex * 12.9898 + 97) * 43758.5453;
  return 1.5 + (x - x.floorToDouble()) * 2;
}

/// 副歌行上一个词的涟漪：active 时 0.5 秒 easeOut 从 0.2 倍扩到 [maxScale] 倍、不透明度
/// 0.8→0；离开 active 时（AnimatePresence exit）从当时的不透明度 0.5 秒淡到 0。null = 不画。
LuminousRipple? luminousRippleAt({
  required double t,
  required LuminousWordSchedule schedule,
  required double maxScale,
}) {
  LuminousRipple at(double time) {
    final double p = luminousTween(
      time - schedule.activeAt,
      0.5,
      luminousEaseOut,
    );
    return LuminousRipple(
      scale: _lerp(0.2, maxScale, p),
      opacity: _lerp(0.8, 0, p),
    );
  }

  switch (schedule.stateAt(t)) {
    case LuminousWordState.waiting:
      return null;
    case LuminousWordState.active:
      return at(t);
    case LuminousWordState.passed:
      if (schedule.passedAt < schedule.activeAt) return null;
      final LuminousRipple from = at(schedule.passedAt);
      final double p = luminousTween(
        t - schedule.passedAt,
        0.5,
        luminousEaseOut,
      );
      if (p >= 1 || from.opacity <= 0) return null;
      return LuminousRipple(scale: from.scale, opacity: from.opacity * (1 - p));
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
double luminousLineExitDuration(LyricVisualizerLineTransition mode) =>
    switch (mode) {
      LyricVisualizerLineTransition.none => 0.12,
      LyricVisualizerLineTransition.fast => 0.16,
      LyricVisualizerLineTransition.normal => 0.3,
    };

/// 入场：[sinceEnter] 是行挂上后经过的秒数。
LuminousLineFx luminousLineEnterFx(
  LyricVisualizerLineTransition mode,
  double sinceEnter,
) {
  switch (mode) {
    case LyricVisualizerLineTransition.none:
      return LuminousLineFx.steady;
    case LyricVisualizerLineTransition.fast:
      final double p = luminousTween(sinceEnter, 0.16, luminousEaseOut);
      return LuminousLineFx(
        opacity: _lerp(0.35, 1, p),
        scale: _lerp(0.96, 1, p),
        blur: _lerp(4, 0, p),
      );
    case LyricVisualizerLineTransition.normal:
      // folia 的 animate 没写 transition，逐属性取 framer 默认：opacity / filter 是
      // cubic-bezier(0.25, 0.1, 0.35, 1) 0.3 秒，scale 是 stiffness 550 / damping 30 的弹簧。
      final double p = luminousTween(sinceEnter, 0.3, luminousEaseDefault);
      final double s = luminousSpring(
        sinceEnter,
        stiffness: luminousDefaultScaleStiffness,
        damping: luminousDefaultScaleDamping,
      );
      return LuminousLineFx(
        opacity: p,
        scale: _lerp(0.9, 1, s),
        blur: _lerp(10, 0, p),
      );
  }
}

/// 离场：[sinceExit] 是开始离场后经过的秒数。
LuminousLineFx luminousLineExitFx(
  LyricVisualizerLineTransition mode,
  double sinceExit,
) {
  final double d = luminousLineExitDuration(mode);
  switch (mode) {
    case LyricVisualizerLineTransition.none:
      final double p = luminousTween(sinceExit, d, luminousEaseOut);
      return LuminousLineFx(
        opacity: 1 - p,
        scale: _lerp(1, 1.02, p),
        blur: 6 * p,
      );
    case LyricVisualizerLineTransition.fast:
      final double p = luminousTween(sinceExit, d, luminousEaseInOut);
      return LuminousLineFx(
        opacity: 1 - p,
        scale: _lerp(1, 1.04, p),
        blur: 10 * p,
      );
    case LyricVisualizerLineTransition.normal:
      // exit 只写了 duration 0.3：framer 默认 easeInOut。
      final double p = luminousTween(sinceExit, d, luminousEaseInOut);
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
  LyricVisualizerIntensity intensity,
) {
  if (multiplier <= 0) return LuminousBreath.none;
  final (double distance, double period) = switch (intensity) {
    LyricVisualizerIntensity.calm => (10.0, 8.5),
    LyricVisualizerIntensity.normal => (14.0, 7.0),
    LyricVisualizerIntensity.chaotic => (18.0, 5.8),
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
