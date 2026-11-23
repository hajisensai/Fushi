/// 凝彩的运动求解（folia `temperaMotionEasing.ts` / `temperaEnterStyles.ts` / `temperaMotion.ts`
/// / `temperaCamera.ts` / `temperaTransitions.ts`）：全部由绝对时间与每字常量算出，拖进度得到
/// 与连续播放完全相同的一帧。
library;

import 'dart:math' as math;

import 'package:fushi/src/media/music/lyrics/visualizer/modes/tempera/tempera_program.dart';

double temperaClamp01(double v) => v.isNaN ? 0 : math.min(1, math.max(0, v));

double _cubic(double p1, double p2, double t) {
  final double inv = 1 - t;
  return 3 * inv * inv * t * p1 + 3 * inv * t * t * p2 + t * t * t;
}

/// CSS cubic-bezier：先二分解 x 再取 y。
double temperaCubicBezier(
  double x1,
  double y1,
  double x2,
  double y2,
  double value,
) {
  final double target = temperaClamp01(value);
  if (target == 0 || target == 1) return target;
  double low = 0;
  double high = 1;
  double p = target;
  for (int i = 0; i < 12; i++) {
    final double x = _cubic(x1, x2, p);
    if (x < target) {
      low = p;
    } else {
      high = p;
    }
    p = (low + high) / 2;
  }
  return _cubic(y1, y2, p);
}

/// 前重的长减速：开头果断，尾巴慢爬。
double temperaEaseEnter(double v) => temperaCubicBezier(0.22, 1, 0.36, 1, v);
double temperaEaseInOut(double v) => temperaCubicBezier(0.62, 0, 0.32, 1, v);

/// 轻微回弹（缩放落位用）。
double temperaEaseSoftBack(double value) {
  final double t = temperaClamp01(value);
  const double c = 1.42;
  return 1 + (c + 1) * math.pow(t - 1, 3) + c * math.pow(t - 1, 2);
}

/// 一个字的入场方式：按词挑一种，相邻词不同。
enum TemperaEnterStyle {
  slide,
  fromLeft,
  fromRight,
  fromAbove,
  fromBelow,
  swing,
  stamp,
}

/// 入场某一刻的位移 / 旋转 / 缩放。
class TemperaEnterFrame {
  const TemperaEnterFrame(
    this.x,
    this.y,
    this.rotation,
    this.scaleX,
    this.scaleY,
    this.echo,
  );

  final double x;
  final double y;
  final double rotation;
  final double scaleX;
  final double scaleY;

  /// 0 = 没有值得拖影的行程（stamp）。
  final double echo;
}

TemperaEnterFrame _directional(
  TemperaGlyphMotionInput g,
  double travel,
  double uniform,
  double dx,
  double dy,
  double rotationScale,
) {
  final double magnitude = math.sqrt(g.enterX * g.enterX + g.enterY * g.enterY);
  final double len = math.sqrt(dx * dx + dy * dy);
  final double l = len == 0 ? 1 : len;
  return TemperaEnterFrame(
    (dx / l) * magnitude * travel,
    (dy / l) * magnitude * travel,
    g.enterRotation * rotationScale * travel,
    uniform,
    uniform,
    travel,
  );
}

/// `travel` 1→0，`linear` 原始 0→1。
TemperaEnterFrame temperaEnterFrame(
  TemperaEnterStyle style,
  TemperaGlyphMotionInput g,
  double travel,
  double linear,
) {
  final double settle = temperaEaseSoftBack(linear);
  final double uniform = g.enterScale + (1 - g.enterScale) * settle;
  switch (style) {
    case TemperaEnterStyle.fromLeft:
      return _directional(g, travel, uniform, -1, 0.12, 0.4);
    case TemperaEnterStyle.fromRight:
      return _directional(g, travel, uniform, 1, -0.12, 0.4);
    case TemperaEnterStyle.fromAbove:
      return _directional(g, travel, uniform, 0.12, -1, 0.4);
    case TemperaEnterStyle.fromBelow:
      return _directional(g, travel, uniform, -0.12, 1, 0.4);
    case TemperaEnterStyle.swing:
      final double sign = g.enterRotation == 0 ? 1 : g.enterRotation.sign;
      return TemperaEnterFrame(
        g.enterX * 0.6 * travel,
        g.enterY * 0.6 * travel,
        (g.enterRotation + sign * 0.95) * travel,
        uniform,
        uniform,
        travel * 0.8,
      );
    case TemperaEnterStyle.stamp:
      return TemperaEnterFrame(
        0,
        0,
        g.enterRotation * 0.6 * travel,
        1 + travel * 0.7,
        1 + travel * 0.7,
        0,
      );
    case TemperaEnterStyle.slide:
      return TemperaEnterFrame(
        g.enterX * travel,
        g.enterY * travel,
        g.enterRotation * travel,
        uniform,
        uniform,
        travel,
      );
  }
}

/// 逐字求解器需要的常量。
class TemperaGlyphMotionInput {
  const TemperaGlyphMotionInput({
    required this.startTime,
    required this.settleTime,
    required this.endTime,
    required this.enterX,
    required this.enterY,
    required this.enterRotation,
    required this.enterScale,
    required this.rotation,
    required this.enterStyle,
    required this.releaseTime,
    required this.trackingX,
    required this.trackingY,
  });

  final double startTime;
  final double settleTime;
  final double endTime;
  final double enterX;
  final double enterY;
  final double enterRotation;
  final double enterScale;
  final double rotation;
  final TemperaEnterStyle enterStyle;
  final double releaseTime;
  final double trackingX;
  final double trackingY;
}

/// 一个字某一刻的姿态。
class TemperaGlyphMotionFrame {
  const TemperaGlyphMotionFrame({
    required this.visible,
    required this.alpha,
    required this.x,
    required this.y,
    required this.rotation,
    required this.scaleX,
    required this.scaleY,
    required this.echoX,
    required this.echoY,
    required this.echoAlpha,
  });

  final bool visible;
  final double alpha;
  final double x;
  final double y;
  final double rotation;
  final double scaleX;
  final double scaleY;
  final double echoX;
  final double echoY;
  final double echoAlpha;
}

const double _currentEmphasis = 0.05;
const double _emphasisDecay = 0.26;
const double _echoAlpha = 0.5;

/// 透明度与拖影最长只走这么久，字在移动中必须可读。
const double _maxRevealWindow = 1.35;

/// 唱完后整块字距外扩的幅度（刚性外扩，不是漂移）。
const double _releaseTracking = 0.055;

/// 一个字的入场 + 唱完后的字距 release。`motion` 为 0 时钉在排版位置。
TemperaGlyphMotionFrame temperaGlyphMotion(
  TemperaGlyphMotionInput g,
  double time,
  double motion,
) {
  final double window = math.max(g.settleTime - g.startTime, 0.08);
  final double linear = temperaClamp01((time - g.startTime) / window);
  final double travel = 1 - temperaEaseEnter(linear);
  final TemperaEnterFrame entrance = temperaEnterFrame(
    g.enterStyle,
    g,
    travel,
    linear,
  );
  final double reveal = temperaClamp01(
    (time - g.startTime) / math.min(window, _maxRevealWindow),
  );
  final double alpha = temperaEaseInOut(temperaClamp01(reveal * 2.4));
  // 当前字用极小的缩放起伏表示（起振→保持→衰减），不画任何衬底。
  final double sung = g.endTime - g.startTime;
  final double attack = math.min(0.12, sung * 0.5);
  final double emphasis = sung <= 0
      ? 0
      : temperaEaseInOut(
              temperaClamp01((time - g.startTime) / math.max(attack, 0.02)),
            ) *
            (1 -
                temperaEaseInOut(
                  temperaClamp01((time - g.endTime) / _emphasisDecay),
                ));
  final double releaseStart = math.max(g.endTime, g.settleTime);
  final double release = temperaEaseInOut(
    temperaClamp01(
      (time - releaseStart) / math.max(g.releaseTime - releaseStart, 0.001),
    ),
  );
  final double amount = temperaClamp01(motion);
  final double spread = release * amount * _releaseTracking;
  final double swell = emphasis * _currentEmphasis * amount;
  return TemperaGlyphMotionFrame(
    visible: time >= g.startTime,
    alpha: alpha,
    x: entrance.x * motion + g.trackingX * spread,
    y: entrance.y * motion + g.trackingY * spread,
    rotation: g.rotation + entrance.rotation * motion,
    scaleX: entrance.scaleX + (1 - entrance.scaleX) * (1 - amount) + swell,
    scaleY: entrance.scaleY + (1 - entrance.scaleY) * (1 - amount) + swell,
    echoX: entrance.x * motion,
    echoY: entrance.y * motion,
    echoAlpha:
        entrance.echo * (1 - temperaEaseEnter(reveal)) * _echoAlpha * amount,
  );
}

/// 分镜时长的比例 → 秒，钳在可看的速度范围。
double temperaShotPaced(
  double shotDuration,
  double fraction,
  double minSeconds,
  double maxSeconds,
) => math.min(maxSeconds, math.max(minSeconds, shotDuration * fraction));

// ---------------------------------------------------------------------------
// 镜头
// ---------------------------------------------------------------------------

/// 镜头姿态（视口比例位移）。
class TemperaCameraFrame {
  TemperaCameraFrame(this.x, this.y, this.scale, this.rotation);

  double x;
  double y;
  double scale;
  double rotation;
}

double _cameraEase(double v) {
  final double t = temperaClamp01(v);
  return t < 0.5 ? 4 * t * t * t : 1 - math.pow(-2 * t + 2, 3) / 2;
}

double _lerp(double a, double b, double t) => a + (b - a) * t;

/// 分镜镜头路径；progress 略超 1 时继续漂，不冻住。
TemperaCameraFrame temperaCameraFrame(TemperaShot shot, double progress) {
  final double c = temperaClamp01(progress);
  final double eased = c * 0.5 + _cameraEase(c) * 0.5;
  final double amount = eased + math.max(0, progress - 1) * 0.35;
  return TemperaCameraFrame(
    _lerp(shot.camera.x, shot.cameraEnd.x, amount),
    _lerp(shot.camera.y, shot.cameraEnd.y, amount),
    _lerp(shot.camera.zoom, shot.cameraEnd.zoom, amount),
    _lerp(shot.camera.rotation, shot.cameraEnd.rotation, amount),
  );
}

/// 手持呼吸：几组不可公度的正弦叠加。
TemperaCameraFrame temperaCameraBreath(double time, double phase) {
  final double tau = time * math.pi * 2;
  return TemperaCameraFrame(
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

/// 字全部落位后再缓入呼吸。
double temperaBreathWeight(double time, double revealDoneTime) =>
    _cameraEase(temperaClamp01((time - revealDoneTime) / 1.2));

// ---------------------------------------------------------------------------
// 段落转场
// ---------------------------------------------------------------------------

/// 段落转场某一刻的姿态。
class TemperaTransitionFrame {
  const TemperaTransitionFrame({
    this.x = 0,
    this.y = 0,
    this.scale = 1,
    this.alpha = 1,
    this.blur = 0,
    this.wipe = 0,
    this.wipeAngle = 0,
  });

  final double x;
  final double y;
  final double scale;
  final double alpha;
  final double blur;

  /// 擦除块 0..2 的行程，1 = 满覆盖。
  final double wipe;
  final double wipeAngle;
}

const TemperaTransitionFrame temperaIdleTransition = TemperaTransitionFrame();

/// 一侧的转场：exit 沿 flow 继续走，enter 从上游沿同一向量进来。
TemperaTransitionFrame temperaTransitionEffect(
  String kind,
  bool exit,
  double progress,
  double flowAngle,
) {
  final double linear = temperaClamp01(progress);
  final double eased = temperaEaseInOut(linear);
  final double fx = math.cos(flowAngle);
  final double fy = math.sin(flowAngle);
  if (kind == 'block-wipe') {
    return TemperaTransitionFrame(
      wipe: exit ? eased : 1 + eased,
      wipeAngle: flowAngle,
    );
  }
  if (kind == 'camera-pan') {
    const double travel = 0.5;
    final double offset = exit ? eased * travel : -(1 - eased) * travel;
    return TemperaTransitionFrame(
      x: fx * offset,
      y: fy * offset,
      scale: 1 + (exit ? eased : 1 - eased) * 0.03,
      alpha: exit
          ? 1 - temperaClamp01((linear - 0.72) / 0.28)
          : temperaClamp01(linear / 0.3),
      wipeAngle: flowAngle,
    );
  }
  final double drift = (exit ? eased : eased - 1) * 0.09;
  final double away = exit ? eased : 1 - eased;
  return TemperaTransitionFrame(
    x: fx * drift,
    y: fy * drift,
    scale: 1 + away * 0.07,
    alpha: exit
        ? 1 - temperaClamp01((linear - 0.55) / 0.45)
        : temperaClamp01(linear / 0.45),
    blur: away * 6,
    wipeAngle: flowAngle,
  );
}

/// 段落的出场转场。
TemperaTransitionFrame temperaExitTransition(
  TemperaParagraph p,
  double time,
  bool enabled,
) {
  final TemperaTransition? tr = p.transitionOut;
  if (!enabled || tr == null || time < tr.startTime) {
    return temperaIdleTransition;
  }
  final double progress =
      (time - tr.startTime) / math.max(tr.endTime - tr.startTime, 0.001);
  return temperaTransitionEffect(
    tr.kind,
    true,
    progress,
    p.shots.isEmpty ? 0 : p.shots.last.flowAngle,
  );
}

/// 段落的入场转场。
TemperaTransitionFrame temperaEnterTransition(
  String? kind,
  double sinceStart,
  double duration,
  bool enabled,
  double flowAngle,
) {
  if (!enabled || kind == null || sinceStart < 0 || sinceStart > duration) {
    return temperaIdleTransition;
  }
  return temperaTransitionEffect(
    kind,
    false,
    sinceStart / math.max(duration, 0.001),
    flowAngle,
  );
}

/// 这一帧某个可见段落该摆的转场姿态（folia `resolveTemperaSceneTransitionFrame`）。
TemperaTransitionFrame temperaSceneTransition(
  TemperaProgram program,
  int index,
  double time,
  bool isIncoming,
  TemperaTransition? outgoing,
  bool enabled,
) {
  final TemperaParagraph p = program.paragraphs[index];
  final TemperaTransition? previous = index > 0
      ? program.paragraphs[index - 1].transitionOut
      : null;
  final double enterDuration = previous == null
      ? 0
      : math.max(0.35, math.min(1, previous.endTime - previous.startTime));
  final double flow = p.shots.isEmpty ? 0 : p.shots.first.flowAngle;
  final bool entering =
      enabled &&
      previous != null &&
      previous.kind == 'block-wipe' &&
      time >= p.startTime &&
      time <= p.startTime + enterDuration;
  if (isIncoming && outgoing != null) {
    return temperaEnterTransition(
      outgoing.kind,
      time - outgoing.startTime,
      math.max(0.001, outgoing.endTime - outgoing.startTime),
      true,
      flow,
    );
  }
  if (entering) {
    return temperaEnterTransition(
      previous.kind,
      time - p.startTime,
      enterDuration,
      true,
      flow,
    );
  }
  return temperaExitTransition(p, time, enabled);
}

/// 场景内当前分镜（起点已到的最后一个）。
int temperaActiveShotIndex(List<TemperaShot> shots, double time) {
  for (int i = shots.length - 1; i >= 0; i--) {
    if (time >= shots[i].startTime) return i;
  }
  return 0;
}

/// 片尾：最后一段唱完后歌词淡出、海报淡入。
class TemperaCreditsFrame {
  const TemperaCreditsFrame({
    required this.active,
    required this.lyricAlpha,
    required this.posterAlpha,
    required this.posterOffsetY,
    required this.posterScale,
  });

  final bool active;
  final double lyricAlpha;
  final double posterAlpha;
  final double posterOffsetY;
  final double posterScale;
}

TemperaCreditsFrame temperaCreditsFrame(double time, double finalEnd) {
  final double poster = temperaEaseInOut((time - finalEnd - 0.9) / 1.1);
  return TemperaCreditsFrame(
    active: time > finalEnd + 0.35,
    lyricAlpha: 1 - temperaEaseInOut((time - finalEnd - 0.1) / 0.9),
    posterAlpha: poster,
    posterOffsetY: (1 - poster) * 0.06,
    posterScale: 0.96 + poster * 0.04,
  );
}
