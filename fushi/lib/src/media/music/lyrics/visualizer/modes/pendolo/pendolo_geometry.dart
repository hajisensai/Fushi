/// 时计的纯几何 / 时间线 / 运动（无 Flutter 绘制依赖，可单测）。对应 folia
/// `pendoloGeometry.ts`、`pendoloTimeline.ts`、`pendoloClockworkMotion.ts`、
/// `pendoloClockworkScene.ts`（锚点）、`pendoloDialProjection.ts`、`pendoloParallax.ts`。
library;

import 'dart:math' as math;

import 'package:flutter/rendering.dart' show Matrix4;

import 'package:fushi/src/media/music/lyrics/visualizer/modes/pendolo/pendolo_tuning.dart';

// ---------------------------------------------------------------------------
// 轮盘布局
// ---------------------------------------------------------------------------

/// 弧上同时排开的句数（folia `visibleWindowCount`）。
const int kPendoloVisibleWindowCount = 9;

/// 相邻两句的角距（弧度）。
double pendoloAngleStepRad(double arcAngleDeg) =>
    arcAngleDeg * math.pi / 180 / (kPendoloVisibleWindowCount - 1);

/// 轮心横坐标：镜像时从右边缘量。
double pendoloWheelCenterX(double viewportWidth, PendoloTuning tuning) =>
    tuning.mirrored
    ? viewportWidth * (1 - tuning.wheelCenterX)
    : viewportWidth * tuning.wheelCenterX;

/// 弧上一句的位置。
class PendoloLineItem {
  const PendoloLineItem({
    required this.index,
    required this.angleRad,
    required this.x,
    required this.y,
    required this.isActive,
    required this.distanceFromActive,
    required this.alpha,
    required this.scale,
  });

  final int index;
  final double angleRad;
  final double x;
  final double y;
  final bool isActive;
  final double distanceFromActive;
  final double alpha;
  final double scale;

  double get angleDeg => angleRad * 180 / math.pi;
}

bool _isInteger(double v) => v == v.roundToDouble();

/// 把歌词排到擒纵轮的弧上（folia `calculatePendoloWheelLayout`）。[targetLineIndex]
/// 是整数时那一句是焦点；间奏里是 `上一句 + 0.5`，弧停在两句之间。[lineBlockHeights]
/// 是每句（含译文、按焦点放大）的高度，弧上间距至少容得下相邻两块。
List<PendoloLineItem> calculatePendoloWheelLayout({
  required int lineCount,
  required double targetLineIndex,
  required double viewportWidth,
  required double viewportHeight,
  required PendoloTuning tuning,
  double radiusOffsetPx = 0,
  List<double>? lineBlockHeights,
}) {
  final double sideSign = tuning.sideSign;
  final double centerX = pendoloWheelCenterX(viewportWidth, tuning);
  final double centerY = viewportHeight * tuning.wheelCenterY;
  final double baseRadius =
      math.min(viewportWidth, viewportHeight) * tuning.arcRadius +
      radiusOffsetPx;
  final double angleStepRad = pendoloAngleStepRad(tuning.arcAngleDeg);
  final bool isIntegerTarget = _isInteger(targetLineIndex);
  final int activeIndex =
      isIntegerTarget && targetLineIndex >= 0 && targetLineIndex < lineCount
      ? targetLineIndex.toInt()
      : -1;
  final List<PendoloLineItem> items = <PendoloLineItem>[];
  if (lineCount == 0) return items;

  final int centerRef = (targetLineIndex >= 0 ? targetLineIndex : 0)
      .floor()
      .clamp(0, lineCount - 1);
  final int windowStart = math.max(0, centerRef - 8);
  final int windowEnd = math.min(lineCount - 1, centerRef + 8);
  final Map<int, double> visualAngles = <int, double>{};

  double heightOf(int i) =>
      lineBlockHeights != null && i >= 0 && i < lineBlockHeights.length
      ? lineBlockHeights[i]
      : 0;

  if (isIntegerTarget &&
      targetLineIndex >= windowStart &&
      targetLineIndex <= windowEnd) {
    final int a = targetLineIndex.toInt();
    visualAngles[a] = 0;
    for (int i = a + 1; i <= windowEnd; i++) {
      final double spacing = math.max(
        angleStepRad,
        (heightOf(i - 1) + heightOf(i) + 24) / (2 * baseRadius),
      );
      visualAngles[i] = (visualAngles[i - 1] ?? 0) + spacing;
    }
    for (int i = a - 1; i >= windowStart; i--) {
      final double spacing = math.max(
        angleStepRad,
        (heightOf(i + 1) + heightOf(i) + 24) / (2 * baseRadius),
      );
      visualAngles[i] = (visualAngles[i + 1] ?? 0) - spacing;
    }
  }

  for (int i = windowStart; i <= windowEnd; i++) {
    final double distanceIndex = i - targetLineIndex;
    final double angle = visualAngles[i] ?? distanceIndex * angleStepRad;
    // 只排在右半圆（离焦点轴 ±90° 内）。
    if (angle.abs() >= math.pi / 2) continue;
    final bool isActive = activeIndex >= 0 && i == activeIndex;
    final double absDistance = distanceIndex.abs();
    final double alpha = math.max(
      0.12,
      math.pow(math.cos(angle * 0.75), 2.5).toDouble() *
          (1 - absDistance * 0.18),
    );
    final double scale = isActive
        ? tuning.activeScale
        : math.max(0.7, 1 - absDistance * 0.08);
    items.add(
      PendoloLineItem(
        index: i,
        angleRad: angle,
        x: centerX + sideSign * baseRadius * math.cos(angle),
        y: centerY + baseRadius * math.sin(angle),
        isActive: isActive,
        distanceFromActive: absDistance,
        alpha: alpha,
        scale: scale,
      ),
    );
  }
  return items;
}

/// 轮盘锚点（folia `resolvePendoloFallbackAnchorIndex`，按时间无状态地算）：正在唱的
/// 那句；间奏里停在上一句与下一句之间（`+0.5`）；第一句之前 -1；全曲唱完 = 句数。
double resolvePendoloAnchorIndex({
  required int lineCount,
  required int activeIndex,
  required int lastStartedIndex,
  required int lastLineEndMs,
  required int timeMs,
}) {
  if (activeIndex >= 0 && activeIndex < lineCount) {
    return activeIndex.toDouble();
  }
  if (lastStartedIndex < 0) return -1;
  if (timeMs > lastLineEndMs) return lineCount.toDouble();
  return lastStartedIndex + 0.5;
}

const double _kVisibleArcDeg = 110;
const double _kEdgeFadeDeg = 28;

/// 句子只在可见弧内显出（folia `resolvePendoloRotatingLineOpacity`）。
double pendoloRotatingLineOpacity(
  double baseAngleDeg,
  double wheelRotationDeg,
  double baseOpacity,
) {
  final double visible = (baseAngleDeg + wheelRotationDeg).abs();
  if (visible >= _kVisibleArcDeg) return 0;
  final double edge = math.min(1, (_kVisibleArcDeg - visible) / _kEdgeFadeDeg);
  return baseOpacity * edge;
}

/// 轮心视角下弧两端的句子淡出：65° 开始淡，75° 看不见。
double pendoloStandEdgeFade(double angleDeg) =>
    ((75 - angleDeg.abs()) / (75 - 65)).clamp(0.0, 1.0);

/// 轮心视角下非焦点句越靠近焦点越淡：紧挨着 0.18，到第 4 句回到 1。
double pendoloStandSideLineAlpha(double distance) =>
    math.min(1, 0.18 + (1 - 0.18) * (math.max(1, distance) - 1) / (4 - 1));

// ---------------------------------------------------------------------------
// 擒纵弹簧（framer-motion useSpring 的等价积分）
// ---------------------------------------------------------------------------

/// 质量-弹簧-阻尼：轮盘跟着锚点一格格跳，略带回弹。
class PendoloSpring {
  PendoloSpring(this.value);

  double value;
  double velocity = 0;

  /// 推进 [dt] 秒趋向 [target]。参数照 folia：stiffness 180·s，damping 18 + 4/s，mass 0.8。
  void step(double target, double dt, double snappiness) {
    final double stiffness = 180 * snappiness;
    final double damping = 18 + 4 / math.max(0.5, snappiness);
    const double mass = 0.8;
    // 半隐式欧拉 + 子步，dt 最大 0.05 时仍稳定。
    final int sub = math.max(1, (dt / 0.004).ceil());
    final double h = dt / sub;
    for (int i = 0; i < sub; i++) {
      final double accel =
          (-stiffness * (value - target) - damping * velocity) / mass;
      velocity += accel * h;
      value += velocity * h;
    }
    if ((value - target).abs() < 1e-4 && velocity.abs() < 1e-3) {
      value = target;
      velocity = 0;
    }
  }

  void snap(double target) {
    value = target;
    velocity = 0;
  }
}

// ---------------------------------------------------------------------------
// 机芯运动（folia `stepPendoloClockworkMotion` 的非随拍分支）
// ---------------------------------------------------------------------------

/// 跨帧的机芯状态：摆轮相位、低音平滑值、秒齿轮弹簧。
class PendoloClockworkMotion {
  double phase = 0;
  double smoothedBass = 0.15;
  double secondGearElapsed = 0;
  int secondGearStep = 0;
  double secondGearAngle = 0;
  double secondGearVelocity = 0;

  /// 摆轮 / 游丝的摆角（弧度），[step] 后有效。
  double bassOscillation = 0;

  /// 推进一帧。[bass] 0–1（Fushi 没有实时频谱，用歌词节拍包络代替）；暂停时只冻结相位。
  void step(double dt, double bass, {required bool paused}) {
    smoothedBass += (bass.clamp(0.0, 1.0) - smoothedBass) * 0.12;
    final double b = smoothedBass;
    if (!paused) {
      phase += dt * (2.8 + b * 3.5);
      secondGearElapsed += dt;
      final int done = secondGearElapsed.floor();
      if (done > 0) {
        secondGearStep += done;
        secondGearElapsed -= done;
      }
      final double target = secondGearStep * (math.pi * 2 / 15);
      secondGearVelocity += (target - secondGearAngle) * 92 * dt;
      secondGearVelocity *= math.exp(-13 * dt);
      secondGearAngle += secondGearVelocity * dt;
    }
    bassOscillation = math.sin(phase) * (0.15 + b * 0.70);
  }
}

// ---------------------------------------------------------------------------
// 机芯锚点（相对轮心，未镜像）
// ---------------------------------------------------------------------------

/// 各齿轮相对轮心的位置与半径（folia `resolvePendoloClockworkAnchors`）。
class PendoloClockworkAnchors {
  PendoloClockworkAnchors(this.baseRadius, double lyricRingRadius)
    : focalAxisEndRadius =
          lyricRingRadius - math.max(14, baseRadius * 0.025).toDouble();

  final double baseRadius;
  final double focalAxisEndRadius;

  double get balanceX => baseRadius * 0.2;
  double get balanceY => -baseRadius * 0.75;
  double get balanceR => baseRadius * 0.28;
  double get transX => baseRadius * 0.32;
  double get transY => baseRadius * 0.78;
  double get transR => baseRadius * 0.34;
  double get secondX => baseRadius * 0.68;
  double get secondY => baseRadius * 0.76;
  double get secondR => baseRadius * 0.16;
  double get idlerX => (transX + secondX) * 0.5 + baseRadius * 0.04;
  double get idlerY => (transY + secondY) * 0.5 - baseRadius * 0.02;
  double get idlerR => baseRadius * 0.08;
  double get orbitR => baseRadius * 0.52;
  double get planetR => baseRadius * 0.16;
  double get coverRadius => baseRadius * 0.88;
  double get gradientR => baseRadius * 1.65;
}

// ---------------------------------------------------------------------------
// 分层视差高度（轮盘半径的比例，folia `pendoloParallax.ts`）
// ---------------------------------------------------------------------------

abstract final class PendoloLayerHeight {
  static const double dialFace = 0;
  static const double ticks = 0.02;
  static const double escapement = 0.05;
  static const double mainSun = 0.09;
  static const double idler = 0.08;
  static const double second = 0.1;
  static const double planet = 0.11;
  static const double trans = 0.14;
  static const double balance = 0.2;
  static const double axis = 0.1;
  static const double lyrics = 0.1;
}

// ---------------------------------------------------------------------------
// 表盘投影（倾斜 / 轮心视角 / 镜像）
// ---------------------------------------------------------------------------

const double _kPerspectiveFactor = 1.2;
const double _kHubViewFocalFactor = 0.75;
const double _kHubViewTargetX = 0.5;
const double _kHubViewTargetY = 0.42;

/// 表盘平面（相对轮心的 px）→ 屏幕（仍相对轮心）的 3x3 单应，行主序。
class PendoloDialProjection {
  const PendoloDialProjection({
    required this.m,
    required this.flat,
    required this.lift,
    required this.invFocal,
  });

  /// `[x', y', w] = m · [x, y, 1]`。
  final List<double> m;

  /// 没有倾斜 / 轮心视角（镜像不算）。
  final bool flat;

  /// 离表盘高 1px 的点在齐次坐标里多出的那份。
  final List<double> lift;
  final double invFocal;

  /// 投一个点；返回屏幕位置（相对轮心）与透视缩放。
  ({double x, double y, double depthScale}) project(double x, double y) {
    final double w = m[6] * x + m[7] * y + m[8];
    final double sw = w > 1e-3 ? w : 1e-3;
    return (
      x: (m[0] * x + m[1] * y + m[2]) / sw,
      y: (m[3] * x + m[4] * y + m[5]) / sw,
      depthScale: 1 / sw,
    );
  }

  /// 平面上 w 大于 [eps] 的那半边（相机前方），用来在轮心视角下裁掉相机背后的部分；
  /// [extent] 是要保留的范围半径。没有透视时返回 null。
  ({double minX, double maxX, double minY, double maxY})? frontHalfPlane(
    double eps,
    double extent,
  ) {
    if (flat) return null;
    double minX = -extent;
    double maxX = extent;
    double minY = -extent;
    double maxY = extent;
    // w = m6·x + m7·y + m8 > eps；轮心视角只有 m6，倾斜两项都有时取主导轴近似。
    if (m[6].abs() >= m[7].abs() && m[6] != 0) {
      final double bound = (eps - m[8]) / m[6];
      if (m[6] > 0) {
        minX = math.max(minX, bound);
      } else {
        maxX = math.min(maxX, bound);
      }
    } else if (m[7] != 0) {
      final double bound = (eps - m[8]) / m[7];
      if (m[7] > 0) {
        minY = math.max(minY, bound);
      } else {
        maxY = math.min(maxY, bound);
      }
    }
    return (minX: minX, maxX: maxX, minY: minY, maxY: maxY);
  }

  /// Canvas 用的 4x4（列主序，与 CSS matrix3d 同构）：之后按「相对轮心」的平面坐标画，
  /// 轮心落在屏幕 [hubX]/[hubY]。
  Matrix4 canvasMatrix(double hubX, double hubY) {
    final Matrix4 plane = Matrix4(
      m[0],
      m[3],
      0,
      m[6], //
      m[1],
      m[4],
      0,
      m[7], //
      0,
      0,
      1,
      0, //
      m[2],
      m[5],
      0,
      m[8],
    );
    return Matrix4.translationValues(hubX, hubY, 0)..multiply(plane);
  }
}

PendoloDialProjection _identity(double focal) => PendoloDialProjection(
  m: const <double>[1, 0, 0, 0, 1, 0, 0, 0, 1],
  flat: true,
  lift: <double>[0, 0, -1 / focal],
  invFocal: 1 / focal,
);

/// 只倾斜（folia `buildPendoloTiltProjection`）：绕过轮心、方向 [axisDeg] 的轴转 [tiltDeg]，透视投回。
PendoloDialProjection buildPendoloTiltProjection(
  double tiltDeg,
  double axisDeg,
  double viewportWidth,
  double viewportHeight,
) {
  final double focal =
      _kPerspectiveFactor *
      math.max(1, math.max(viewportWidth, viewportHeight)).toDouble();
  if (tiltDeg == 0) return _identity(focal);
  final double theta =
      tiltDeg.clamp(-kPendoloTiltLimitDeg, kPendoloTiltLimitDeg) *
      math.pi /
      180;
  final double phi = axisDeg * math.pi / 180;
  final double ux = math.cos(phi);
  final double uy = math.sin(phi);
  final double c = math.cos(theta);
  final double s = math.sin(theta);
  final double k = 1 - c;
  return PendoloDialProjection(
    m: <double>[
      c + ux * ux * k, ux * uy * k, 0, //
      ux * uy * k, c + uy * uy * k, 0, //
      uy * s / focal, -ux * s / focal, 1,
    ],
    flat: false,
    lift: <double>[uy * s, -ux * s, -c / focal],
    invFocal: 1 / focal,
  );
}

/// 轮心视角（folia `buildPendoloHubViewProjection`）：相机在轮心后上方顺着刻度针看焦点句。
PendoloDialProjection buildPendoloHubViewProjection({
  required double cameraHeightPx,
  required double backDistancePx,
  required double targetDistancePx,
  required double side,
  required double hubX,
  required double hubY,
  required double viewportWidth,
  required double viewportHeight,
}) {
  final double s = side;
  final double h = math.max(1, cameraHeightPx).toDouble();
  final double b = math.max(0, backDistancePx).toDouble();
  final double d = math.max(1, targetDistancePx).toDouble();
  final double dc = d + b;
  final double l2 = dc * dc + h * h;
  final double l = math.sqrt(l2);
  final double f =
      _kHubViewFocalFactor *
      math.max(1, math.max(viewportWidth, viewportHeight)).toDouble();
  final double sx = viewportWidth * _kHubViewTargetX - hubX;
  final double sy = viewportHeight * _kHubViewTargetY - hubY;
  final double w0 = s * dc / l2;
  final double wc = (dc * b + h * h) / l2;
  final double lw = -h / l2;
  return PendoloDialProjection(
    m: <double>[
      sx * w0, f * s / l, sx * wc, //
      -f * s * h / l2 + sy * w0, 0, f * d * h / l2 + sy * wc, //
      w0, 0, wc,
    ],
    flat: false,
    lift: <double>[sx * lw, -f * dc / l2 + sy * lw, lw],
    invFocal: 0,
  );
}

/// 表盘本身：先左右镜像，再倾斜（第一列取反）。
PendoloDialProjection buildPendoloDialProjection(
  PendoloDialProjection tilt, {
  required bool mirrored,
}) {
  if (!mirrored) return tilt;
  final List<double> m = tilt.m;
  return PendoloDialProjection(
    m: <double>[-m[0], m[1], m[2], -m[3], m[4], m[5], -m[6], m[7], m[8]],
    flat: tilt.flat,
    lift: tilt.lift,
    invFocal: tilt.invFocal,
  );
}

/// 离表盘高 [heightPx] 的一层（folia `buildPendoloLayerProjection`）：平放时与表盘一致。
PendoloDialProjection buildPendoloLayerProjection(
  PendoloDialProjection p,
  double heightPx,
) {
  if (p.flat || heightPx == 0) return p;
  final List<double> m = p.m;
  final double shrink = 1 - heightPx * p.invFocal;
  return PendoloDialProjection(
    m: <double>[
      m[0] * shrink, m[1] * shrink, m[2] + heightPx * p.lift[0], //
      m[3] * shrink, m[4] * shrink, m[5] + heightPx * p.lift[1], //
      m[6] * shrink, m[7] * shrink, m[8] + heightPx * p.lift[2],
    ],
    flat: false,
    lift: p.lift,
    invFocal: p.invFocal,
  );
}
