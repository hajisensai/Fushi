/// 商籁的纯时间运动求值（folia `sonnetMotion.ts` / `sonnetTransitions.ts` /
/// `sonnetSceneFrame.ts` / `sonnetCameraTracking.ts` / `sonnetCredits.ts`）：缓动、镜头路径、
/// 呼吸、焦点权重与平滑、转场帧、片尾帧。全部只吃绝对时间（秒），跳转与连续播放同帧。
library;

import 'dart:math' as math;

import 'package:fushi/src/media/music/lyrics/visualizer/modes/sonnet/sonnet_program.dart';

double sonnetClamp01(double v) => math.min(1, math.max(0, v));

double _cubicCoordinate(double p1, double p2, double t) {
  final double inv = 1 - t;
  return 3 * inv * inv * t * p1 + 3 * inv * t * t * p2 + t * t * t;
}

/// CSS 式 cubic-bezier：先在 x 曲线上二分求参数，再取 y。
double resolveSonnetCubicBezier(
  double x1,
  double y1,
  double x2,
  double y2,
  double value,
) {
  final double target = sonnetClamp01(value);
  if (target == 0 || target == 1) return target;
  double low = 0;
  double high = 1;
  double parameter = target;
  for (int i = 0; i < 12; i++) {
    final double x = _cubicCoordinate(x1, x2, parameter);
    if (x < target) {
      low = parameter;
    } else {
      high = parameter;
    }
    parameter = (low + high) / 2;
  }
  return _cubicCoordinate(y1, y2, parameter);
}

double easeSonnetInOut(double v) =>
    resolveSonnetCubicBezier(0.65, 0, 0.35, 1, v);

double easeSonnetExpoOut(double v) =>
    v == 1 ? 1 : 1 - math.pow(2, -10 * v).toDouble();

double easeSonnetElasticOut(double v) {
  const double p = 0.3;
  return math.pow(2, -10 * v) * math.sin((v - p / 4) * (2 * math.pi) / p) + 1;
}

double resolveSonnetShotProgress(SonnetShot shot, double time) =>
    sonnetClamp01((time - shot.start) / math.max(shot.end - shot.start, 0.001));

/// 单字入场进度（ExpoOut 的「打击感」）。
double resolveSonnetSegmentProgress(double start, double end, double time) =>
    easeSonnetExpoOut(
      sonnetClamp01((time - start) / math.max(end - start, 0.08)),
    );

/// 镜头的一帧偏移（x / y 以视口比例计）。
class SonnetMotionFrame {
  SonnetMotionFrame(this.x, this.y, this.scale, this.rotation);

  double x;
  double y;
  double scale;
  double rotation;
}

double resolveSonnetShotPathProgress(SonnetShotKind kind, double progress) {
  final double linear = sonnetClamp01(progress);
  if (kind == SonnetShotKind.trackingRibbon ||
      kind == SonnetShotKind.fragmentCollage ||
      kind == SonnetShotKind.quietTableau ||
      kind == SonnetShotKind.posterBlocks) {
    return linear * 0.55 + easeSonnetInOut(linear) * 0.45;
  }
  if (linear < 0.18) return easeSonnetExpoOut(linear / 0.18) * 0.22;
  if (linear < 0.78) return 0.22 + ((linear - 0.18) / 0.6) * 0.56;
  final double settle = (linear - 0.78) / 0.22;
  return 0.78 + (1 - (1 - settle) * (1 - settle)) * 0.22;
}

/// 每种镜头的确定性运镜路径。
SonnetMotionFrame resolveSonnetShotMotionFrame(
  SonnetShotKind kind,
  double progress,
) {
  final double linear = sonnetClamp01(progress);
  final double e = resolveSonnetShotPathProgress(kind, linear);
  switch (kind) {
    case SonnetShotKind.editorialColumn:
      return SonnetMotionFrame(
        -0.055 + e * 0.095,
        0.025 - e * 0.04,
        0.98 + e * 0.07,
        -0.006 + e * 0.01,
      );
    case SonnetShotKind.typeImpact:
      return SonnetMotionFrame(
        -0.035 + e * 0.07,
        0.018 - e * 0.028,
        1 +
            (1 - easeSonnetExpoOut(math.min(linear / 0.18, 1))) * 0.22 +
            e * 0.08,
        -0.01 + e * 0.016,
      );
    case SonnetShotKind.fragmentCollage:
      return SonnetMotionFrame(
        -0.045 + e * 0.085,
        0.028 - math.sin(e * math.pi) * 0.055,
        0.97 + e * 0.09,
        -0.014 + e * 0.028,
      );
    case SonnetShotKind.trackingRibbon:
      return SonnetMotionFrame(
        -0.16 + e * 0.28,
        0.05 - e * 0.085,
        0.98 + e * 0.07,
        0.008 - e * 0.014,
      );
    case SonnetShotKind.maskReveal:
      return SonnetMotionFrame(
        0.035 - e * 0.065,
        0.1 - e * 0.135,
        0.96 + e * 0.12,
        -0.006 + e * 0.009,
      );
    case SonnetShotKind.posterBlocks:
      return SonnetMotionFrame(
        -0.012 + e * 0.024,
        0.008 - e * 0.016,
        0.99 + e * 0.025,
        -0.0015 + e * 0.003,
      );
    case SonnetShotKind.quietTableau:
      return SonnetMotionFrame(
        -0.022 + e * 0.04,
        0.014 - e * 0.025,
        1 + e * 0.028,
        -0.002 + e * 0.003,
      );
  }
}

/// 手持呼吸：几条互不通约的正弦叠加。
SonnetMotionFrame resolveSonnetCameraBreath(double time, double phase) {
  final double tau = time * math.pi * 2;
  return SonnetMotionFrame(
    (math.sin(tau * 0.13 + phase) * 0.65 +
            math.sin(tau * 0.31 + phase * 1.7) * 0.35) *
        0.006,
    (math.cos(tau * 0.11 + phase * 2.3) * 0.65 +
            math.sin(tau * 0.29 + phase * 0.9) * 0.35) *
        0.006,
    math.sin(tau * 0.09 + phase * 1.3) * 0.002,
    math.sin(tau * 0.07 + phase * 2.9) * 0.0015,
  );
}

/// 歌词揭示完后 1.2 秒内把呼吸淡入。
double resolveSonnetBreathWeight(double time, double revealDone) =>
    easeSonnetInOut(sonnetClamp01((time - revealDone) / 1.2));

/// 焦点权重：按离每段时间窗的距离做高斯，再归一。
List<double> resolveSonnetFocusWeights(
  List<(double, double)> ranges,
  double time,
) {
  if (ranges.isEmpty) return const <double>[];
  const double sigma = 0.35;
  final List<double> logs = <double>[
    for (final (double a, double b) in ranges)
      () {
        final double s = math.min(a, b);
        final double e = math.max(a, b);
        final double d = time < s ? s - time : (time > e ? time - e : 0);
        return -(d * d) / (2 * sigma * sigma);
      }(),
  ];
  final double maxLog = logs.reduce(math.max);
  final List<double> w = <double>[
    for (final double l in logs) math.exp(l - maxLog),
  ];
  final double total = w.fold(0, (double a, double b) => a + b);
  return <double>[for (final double x in w) x / total];
}

/// 保边的时间平滑：五点加权，离中心太远（构图跳切）的采样不参与平均。
(double, double) resolveSonnetSmoothedFocus(
  double time,
  double start,
  double end,
  (double, double) Function(double t) sample,
) {
  const double radius = 0.12;
  const double maxDist = 96;
  final double s = math.min(start, end);
  final double e = math.max(start, end);
  if (s == e) return sample(math.min(e, math.max(s, time)));
  const List<(double, double)> taps = <(double, double)>[
    (-1, 1),
    (-0.5, 4),
    (0, 6),
    (0.5, 4),
    (1, 1),
  ];
  final List<(double, double, double)> pts = <(double, double, double)>[
    for (final (double off, double w) in taps)
      () {
        final (double x, double y) = sample(
          math.min(e, math.max(s, time + off * radius)),
        );
        return (x, y, w);
      }(),
  ];
  final double cx = pts[2].$1;
  final double cy = pts[2].$2;
  double x = 0;
  double y = 0;
  double total = 0;
  for (final (double px, double py, double w) in pts) {
    final double d2 = (px - cx) * (px - cx) + (py - cy) * (py - cy);
    if (d2 > maxDist * maxDist) continue;
    x += px * w;
    y += py * w;
    total += w;
  }
  return (x / total, y / total);
}

/// 一段的镜头焦点：在相邻字之间按时间插值，再向段中心收一半（trackingFactor 0.5）。
(double, double) resolveSonnetSegmentCameraFocus(
  List<(double, double, double)> glyphs,
  double time,
) {
  if (glyphs.isEmpty) return (0, 0);
  final (double fx, double fy, double fs) = glyphs.first;
  final (double lx, double ly, double ls) = glyphs.last;
  final double cx = (fx + lx) / 2;
  final double cy = (fy + ly) / 2;
  (double, double) apply(double x, double y) =>
      (cx + (x - cx) * 0.5, cy + (y - cy) * 0.5);
  if (time <= fs) return apply(fx, fy);
  if (time >= ls) return apply(lx, ly);
  for (int i = 0; i < glyphs.length - 1; i++) {
    final (double ax, double ay, double at) = glyphs[i];
    final (double bx, double by, double bt) = glyphs[i + 1];
    if (time < at || time > bt) continue;
    final double p = (time - at) / math.max(0.001, bt - at);
    return apply(ax + (bx - ax) * p, ay + (by - ay) * p);
  }
  return apply(fx, fy);
}

/// 字形入场动画时长：镜头时长的 42%，夹在 0.65–1.8 秒且不超过镜头的 72%。
double resolveSonnetGlyphMotionDuration(double start, double end) {
  final double shot = math.max(0.001, end - start);
  final double preferred = math.min(1.8, math.max(0.65, shot * 0.42));
  return math.min(preferred, shot * 0.72);
}

// ---------------------------------------------------------------------------
// 转场
// ---------------------------------------------------------------------------

class SonnetTransitionFrame {
  const SonnetTransitionFrame({
    this.alpha = 1,
    this.blur = 0,
    this.glitch = 0,
    this.glitchSeed = 0,
  });

  final double alpha;

  /// Pixi BlurFilter strength。
  final double blur;
  final double glitch;
  final double glitchSeed;

  bool get isIdle => alpha == 1 && blur == 0 && glitch == 0;
}

const SonnetTransitionFrame sonnetIdleTransition = SonnetTransitionFrame();

SonnetTransitionKind _boundaryKind(int seed, int boundaryIndex) {
  final int mixed =
      (seed ^ sonnetImul(boundaryIndex + 1, 0x9e3779b1)) & 0xFFFFFFFF;
  return SonnetTransitionKind.values[mixed %
      SonnetTransitionKind.values.length];
}

/// 单色转场的一帧（不做 RGB 色散）。镜头推拉转场在 folia 里也只剩淡入淡出：缩放会露出滤镜边界。
SonnetTransitionFrame resolveSonnetTransitionEffect(
  SonnetTransitionKind kind,
  bool exit,
  double progress,
  int seed,
) {
  final double linear = sonnetClamp01(progress);
  final double eased = easeSonnetInOut(linear);
  final double amount = exit ? eased : 1 - eased;
  switch (kind) {
    case SonnetTransitionKind.fastBlur:
      return SonnetTransitionFrame(
        alpha: exit ? 1 - amount : 1 - amount * 0.82,
        blur: amount * 14,
      );
    case SonnetTransitionKind.monoGlitch:
      final int step = (linear * 14).floor();
      return SonnetTransitionFrame(
        alpha: exit && linear > 0.86 ? 1 - (linear - 0.86) / 0.14 : 1,
        glitch: amount,
        glitchSeed: seed * 0.0001 + step * 0.173,
      );
    case SonnetTransitionKind.cameraPull:
      return SonnetTransitionFrame(
        alpha: exit ? 1 - amount : 1 - amount * 0.72,
      );
  }
}

SonnetTransitionFrame _exitFrame(
  SonnetParagraph p,
  double time,
  bool enabled,
  int seed,
) {
  final SonnetTransition? t = p.transitionOut;
  if (!enabled || t == null || time < t.start) return sonnetIdleTransition;
  final double progress = (time - t.start) / math.max(t.end - t.start, 0.001);
  return resolveSonnetTransitionEffect(t.kind, true, progress, seed);
}

SonnetTransitionFrame _enterFrame(
  SonnetTransitionKind? kind,
  double since,
  double duration,
  bool enabled,
  int seed,
) {
  if (!enabled || kind == null || since < 0 || since > duration) {
    return sonnetIdleTransition;
  }
  return resolveSonnetTransitionEffect(
    kind,
    false,
    since / math.max(duration, 0.001),
    seed,
  );
}

SonnetTransitionFrame _shotFrame(
  List<SonnetShot> shots,
  int active,
  double time,
  bool enabled,
  int seed,
) {
  if (!enabled || shots.length < 2 || active < 0 || active >= shots.length) {
    return sonnetIdleTransition;
  }
  final SonnetShot current = shots[active];
  if (active > 0) {
    final SonnetShot previous = shots[active - 1];
    final double d = math.min(
      0.24,
      math.max(0.14, (current.start - previous.start) * 0.18),
    );
    if (time <= current.start + d) {
      return _enterFrame(
        _boundaryKind(seed, active - 1),
        time - current.start,
        d,
        true,
        seed + active * 97,
      );
    }
  }
  if (active + 1 >= shots.length) return sonnetIdleTransition;
  final SonnetShot next = shots[active + 1];
  final double d = math.min(
    0.24,
    math.max(0.14, (next.start - current.start) * 0.18),
  );
  final double tStart = next.start - d;
  if (time < tStart) return sonnetIdleTransition;
  return resolveSonnetTransitionEffect(
    _boundaryKind(seed, active),
    true,
    (time - tStart) / d,
    seed + (active + 1) * 97,
  );
}

/// 场景内当前唯一可见的镜头（起点已到的最后一个，都没到时为 0）。
int findSonnetActiveShotIndex(List<SonnetShot> shots, double time) {
  for (int i = shots.length - 1; i >= 0; i--) {
    if (time >= shots[i].start) return i;
  }
  return 0;
}

/// 段落场景这一帧的转场：镜头边界转场优先，否则段落的入场 / 出场转场。
SonnetTransitionFrame resolveSonnetSceneTransition(
  SonnetProgram program,
  int index,
  int visibleShot,
  double time,
  bool enabled,
) {
  final SonnetParagraph paragraph = program.paragraphs[index];
  final int seed = hashSonnetSeed(
    '${program.seed}:${paragraph.id}:transition-frame',
  );
  final SonnetTransition? previous = index > 0
      ? program.paragraphs[index - 1].transitionOut
      : null;
  final double enterDuration = previous == null
      ? 0
      : math.max(0.16, math.min(0.3, previous.end - previous.start));
  final bool entering =
      enabled &&
      previous != null &&
      time >= paragraph.start &&
      time <= paragraph.start + enterDuration;
  final SonnetTransitionFrame paragraphFrame = entering
      ? _enterFrame(
          previous.kind,
          time - paragraph.start,
          enterDuration,
          true,
          seed,
        )
      : _exitFrame(paragraph, time, enabled, seed);
  final SonnetTransitionFrame shotFrame = _shotFrame(
    paragraph.shots,
    visibleShot,
    time,
    enabled,
    seed,
  );
  return identical(shotFrame, sonnetIdleTransition)
      ? paragraphFrame
      : shotFrame;
}

// ---------------------------------------------------------------------------
// 片尾
// ---------------------------------------------------------------------------

class SonnetCreditsFrame {
  const SonnetCreditsFrame({
    required this.active,
    required this.lyricAlpha,
    required this.lyricBlur,
    required this.posterAlpha,
    required this.posterOffsetY,
    required this.posterScale,
  });

  final bool active;
  final double lyricAlpha;
  final double lyricBlur;
  final double posterAlpha;
  final double posterOffsetY;
  final double posterScale;
}

/// 末句之后：歌词失焦淡出，片尾海报错开升起。
SonnetCreditsFrame resolveSonnetCreditsFrame(double time, double finalEnd) {
  final double elapsed = time - finalEnd;
  if (elapsed <= 0) {
    return const SonnetCreditsFrame(
      active: false,
      lyricAlpha: 1,
      lyricBlur: 0,
      posterAlpha: 0,
      posterOffsetY: 0.04,
      posterScale: 0.965,
    );
  }
  final double exit = easeSonnetInOut(sonnetClamp01(elapsed / 1.25));
  final double enter = easeSonnetInOut(sonnetClamp01((elapsed - 0.38) / 1.55));
  return SonnetCreditsFrame(
    active: true,
    lyricAlpha: 1 - exit,
    lyricBlur: exit * 18,
    posterAlpha: enter,
    posterOffsetY: (1 - enter) * 0.04,
    posterScale: 0.965 + enter * 0.035,
  );
}
