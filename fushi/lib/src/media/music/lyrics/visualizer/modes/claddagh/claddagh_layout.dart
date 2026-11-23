/// 回环的环形排布（移植 folia `claddagh/claddaghLayout.ts` 与 `CladdaghRingLine.tsx` 的每帧几何）：
/// 字素前缀宽度 → 沿环的名义角；每帧把一个字投影到倾斜的扁椭圆上，算出位置、切线角、
/// 纵深缩放、透明度、发光与模糊。纯 Dart（测量通过注入的函数），可单测。
library;

import 'dart:math' as math;

import 'package:fushi/src/media/music/lyrics/visualizer/modes/claddagh/claddagh_timeline.dart';

/// 整行最多占的弧度（超过就整体压缩，字号一并缩）。
const double kCladdaghMaxArcSpan = 4.25;

/// 字距（em），排版与测量共用。
const double kCladdaghLetterSpacingEm = 0.04;

/// 每个字间隙额外加的跟踪量（em）。
const double kCladdaghBaseTrackingEm = 0.18;

/// 当前行之后的行跟随当前行转动的比例。
const double kCladdaghBackFollowRatio = 0.28;

/// 当前行唱完时后面的行额外绕过的半圈比例。
const double kCladdaghBackOrbitFollowRatio = 0.52;

/// 下一行提前多少毫秒开始淡入。
const double kCladdaghNextLineEntryLeadMs = 340;

/// 译文默认字号相对歌词的比例。
const double kCladdaghTranslationFontRatio = 0.5;

/// folia 的字号基准（px），乘以字号倍数。
const double kCladdaghBaseFontPx = 72;

double _fallbackGraphemeWidth(String char, double fontPx) {
  if (char.trim().isEmpty) return fontPx * 0.36;
  if (claddaghIsCjkChar(char)) return fontPx;
  return fontPx * 0.62;
}

/// 让沿切线的字不倒过来：角度规整到 [-90, 90]。
double claddaghReadableAngle(double degrees) {
  double d = degrees;
  while (d > 90) {
    d -= 180;
  }
  while (d < -90) {
    d += 180;
  }
  return d;
}

/// 每个字素边界处的累计宽度（长度 n+1，首项 0）：实测前缀宽 + 字间跟踪 + 字距偏移，单调不减。
/// [measurePrefix] 给出前 count 个字素的排版宽度（含 [kCladdaghLetterSpacingEm] 字距）。
List<double> claddaghPrefixOffsets(
  List<String> graphemes,
  double fontPx,
  double letterSpacingOffsetPx,
  double Function(int count) measurePrefix,
) {
  final List<double> offsets = List<double>.filled(graphemes.length + 1, 0);
  double fallbackWidth = 0;
  for (int count = 1; count <= graphemes.length; count++) {
    fallbackWidth += _fallbackGraphemeWidth(graphemes[count - 1], fontPx);
    final double measured = measurePrefix(count);
    final double width = measured.isFinite && measured > 0
        ? measured
        : fallbackWidth;
    final int gaps = math.max(0, count - 1);
    offsets[count] = math.max(
      offsets[count - 1],
      width +
          gaps * fontPx * kCladdaghBaseTrackingEm +
          gaps * letterSpacingOffsetPx,
    );
  }
  return offsets;
}

/// 一个字素在环上的名义角与整行压缩比。
typedef CladdaghArc = ({double nominalAngle, double scaleFactor});

/// 累计宽度 → 沿环的名义角（以整行中点为 0）。整行超过 [kCladdaghMaxArcSpan] 时等比压缩。
List<CladdaghArc> claddaghArcs(
  List<double> offsets,
  double fontPx,
  double radiusPx,
  double spacingScale,
) {
  final int n = offsets.length - 1;
  if (n <= 0) return const <CladdaghArc>[];
  final double safeScale = spacingScale.isFinite
      ? math.max(0.1, spacingScale)
      : 1;
  final double totalWidth = offsets[n] * safeScale;
  final double safeRadius = math.max(math.max(radiusPx, fontPx * 2), 1);
  final double totalSpan = totalWidth / safeRadius;
  final double scaleFactor = totalSpan > kCladdaghMaxArcSpan
      ? kCladdaghMaxArcSpan / totalSpan
      : 1.0;
  return <CladdaghArc>[
    for (int i = 0; i < n; i++)
      (
        nominalAngle:
            (((offsets[i] + offsets[i + 1]) / 2 * safeScale) / safeRadius -
                totalSpan / 2) *
            scaleFactor,
        scaleFactor: scaleFactor,
      ),
  ];
}

/// 一行在这一帧的整体状态（与字无关的部分，folia `handler` 前半段）。
class CladdaghLineState {
  const CladdaghLineState({
    required this.lineIndex,
    required this.centerLineIndex,
    required this.lineDiffFromCenter,
    required this.wordOffset,
    required this.lengthFade,
    required this.lengthScale,
    required this.upcomingEntry,
  });

  final int lineIndex;
  final int centerLineIndex;

  /// 与焦点行相差几行（按环转角连续变化，0 = 正在焦点）。
  final double lineDiffFromCenter;

  /// 整行沿环转过的角度（弧度）。
  final double wordOffset;

  /// 当前行很长时后面行的淡出 / 缩小（避免互相叠住）。
  final double lengthFade;
  final double lengthScale;

  /// 下一行提前淡入的进度 0–1。
  final double upcomingEntry;

  bool get isUpcoming => lineIndex > centerLineIndex;
  bool get isPast => lineIndex < centerLineIndex;
}

/// 当前行很长时，后面的行在转到前半环前淡掉、缩小。
({double fade, double scale}) claddaghLengthMitigation({
  required bool isUpcoming,
  required double currentLen,
  required double targetLen,
  required double lineDiffFromCenter,
}) {
  if (!isUpcoming || currentLen <= 10) return (fade: 1.0, scale: 1.0);
  final double fadeStrength = claddaghClamp((currentLen - 10) / 8, 0, 1);
  final double targetStrength = claddaghClamp((targetLen - 5) / 5, 0.4, 1);
  final double combined = fadeStrength * targetStrength;
  final double minOpacity = 1.0 - combined;
  final double minScale = 1.0 - combined * 0.25;
  final double tp = claddaghClamp((lineDiffFromCenter - 0.4) / 0.5, 0, 1);
  return (
    fade: 1.0 - (1.0 - minOpacity) * tp,
    scale: 1.0 - (1.0 - minScale) * tp,
  );
}

/// 一个字在这一帧的几何（相对环心，像素）。
class CladdaghPose {
  const CladdaghPose({
    required this.x,
    required this.y,
    required this.rotationDeg,
    required this.scale,
    required this.opacity,
    required this.blur,
    required this.depth,
    required this.focus,
    required this.deltaDist,
  });

  final double x;
  final double y;
  final double rotationDeg;
  final double scale;
  final double opacity;

  /// 模糊（CSS `blur()` 的 px，即高斯标准差）。
  final double blur;

  /// 纵深 D：1 在正前，0 在背面。
  final double depth;

  /// 聚焦 F：1 = 当前行正在唱的字，0 = 远处。
  final double focus;

  /// 沿弧到正前方的距离（px）。
  final double deltaDist;
}

/// 环的几何参数（一帧内所有字共用）。
class CladdaghRing {
  CladdaghRing({
    required this.rx,
    required this.ellipseTiltDeg,
    required this.lineOffset,
  }) : rMinor = rx * 0.09,
       _cos = math.cos(-ellipseTiltDeg * math.pi / 180),
       _sin = math.sin(-ellipseTiltDeg * math.pi / 180);

  /// 长半轴（已乘节拍缩放）。
  final double rx;

  /// 扁椭圆的短半轴。
  final double rMinor;
  final double ellipseTiltDeg;

  /// 环整体转角（行切换的弹簧，焦点行 i 时为 i·π）。
  final double lineOffset;
  final double _cos;
  final double _sin;

  /// 把一个字投影到环上。[rawYOffset] 是短轴方向的固定偏移；[extraMinor] 是沿短轴外推、
  /// 随纵深缩放的距离（译文排在歌词下方用）。
  CladdaghPose pose({
    required CladdaghLineState line,
    required double nominalAngle,
    double rawYOffset = 0,
    double extraMinor = 0,
  }) {
    final double theta = line.lineIndex * math.pi + nominalAngle;
    final double psi = theta - lineOffset - line.wordOffset;
    final double deltaDist = psi * rx;
    final double thetaCurve = deltaDist / rx;
    final double localCos = math.cos(thetaCurve);
    final double d = (localCos + 1) / 2;
    final double depthScale = 0.22 + 0.98 * math.pow(d, 1.5);
    // 背面的字沿长轴收拢。
    final double spacingFactor = 0.35 + 0.65 * math.pow(d, 1.2);
    final double rawX = math.sin(thetaCurve) * rx * spacingFactor;
    final double rawY =
        localCos * rMinor + rawYOffset + extraMinor * depthScale;
    final double x = rawX * _cos - rawY * _sin;
    final double y = rawX * _sin + rawY * _cos;

    final double tx = math.cos(thetaCurve) * rx;
    final double ty = -math.sin(thetaCurve) * rMinor;
    final double tangent = claddaghReadableAngle(
      math.atan2(tx * _sin + ty * _cos, tx * _cos - ty * _sin) * 180 / math.pi,
    );

    final double diff = line.lineDiffFromCenter;
    final double activeLineFactor = math.max(0, 1 - diff);
    final double maxVisibleDist = rx * 0.48;
    final double distRatio = math.min(1, deltaDist.abs() / maxVisibleDist);
    final double f = activeLineFactor * math.pow(1 - distRatio, 1.8).toDouble();

    final double distanceOpacity = 0.68 + 0.32 * math.pow(d, 1.9);
    double opacity =
        (0.35 + 0.65 * math.pow(d, 1.5) * (0.35 + 0.65 * f)) * distanceOpacity;
    // 下一行在上一行前半环还没转走时先藏着。
    opacity *= claddaghClamp(2 - diff, 0, 1);
    if (line.isPast) opacity *= math.max(0, 1 - diff);
    opacity *= line.lengthFade;
    if (line.isUpcoming) opacity *= 0.18 + 0.82 * line.upcomingEntry;
    // 非焦点行只留在椭圆后半。
    if (diff > 0.02) {
      final double progress = claddaghClamp((diff - 0.3) / 0.6, 0, 1);
      final double cosThreshold = 1.0 - 1.2 * progress;
      if (localCos > cosThreshold) {
        opacity *= claddaghClamp(1.0 - (localCos - cosThreshold) / 0.15, 0, 1);
      }
    }

    return CladdaghPose(
      x: x,
      y: y,
      rotationDeg: claddaghClamp(tangent * (0.4 + 0.6 * d), -38, 38),
      scale: depthScale,
      opacity: claddaghClamp(opacity, 0, 1),
      blur: 8.0 * (1 - d) * (1 - 0.5 * f),
      depth: d,
      focus: f,
      deltaDist: deltaDist,
    );
  }
}

/// 字的唱进度 0–1（按调整过的字时长）。
double claddaghCharProgress(CladdaghGlyph g, double t) {
  if (t >= g.endMs) return 1;
  if (t > g.startMs) {
    final double dur = g.endMs - g.startMs;
    return dur > 0 ? (t - g.startMs) / dur : 1;
  }
  return 0;
}

/// 一个字的「闪光」上色：唱到就几乎瞬间切成高亮色，发光半径短暂冲高。
/// 返回 (混色比 0–1, 不透明度, 发光冲高系数)。
({double mix, double alpha, double flashPop}) claddaghFlash(double progress) {
  if (progress >= 1) return (mix: 1.0, alpha: 1.0, flashPop: 0.0);
  if (progress <= 0) return (mix: 0.0, alpha: 0.55, flashPop: 0.0);
  final double pf = math.min(1.0, progress * 15.0);
  final double pop = progress < 0.4
      ? math.pow(1 - progress / 0.4, 2.0) * 0.65
      : 0.0;
  return (mix: pf, alpha: 0.55 + 0.45 * pf, flashPop: pop);
}
