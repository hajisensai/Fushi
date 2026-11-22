/// 时计的动画强度档位与鼓面效果（folia `pendoloMotionProfile.ts`、`pendoloBeatFx.ts`、
/// `usePendoloBeatFx.ts` 的鼓击分支、`pendoloBeatFxDraw.ts` 的 Canvas2D 叠加层）。
///
/// folia 现行的随拍效果只剩「仿真鼓面」：鼓 stem 的每一下鼓击就地点亮轮心光晕、宝石轴承闪光、
/// 两圈表盘亮起，强的一下还让整个表盘鼓起、屏幕抖一下（拍点列表驱动的冲击波 / 火花 / 齿轮随拍
/// 2026-10-17 已被 folia 退役）。Fushi 的鼓击来自共享音频帧的 `drumImpact`（击点强度 × 衰减），
/// 这里从它的上升沿还原出每一下鼓击。纯 Dart，可单测。
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/pendolo/pendolo_geometry.dart';

// ─── 动画强度档位（folia pendoloMotionProfile.ts） ────────────────────────────

/// 一档动画强度下的各项倍率。
class PendoloMotionProfile {
  const PendoloMotionProfile({
    required this.balanceSpeed,
    required this.balanceAmplitude,
    required this.bassResponse,
    required this.escapementSpring,
    required this.escapementDamping,
    required this.chorusHaloOpacity,
    required this.chorusHaloScale,
    required this.chorusGlow,
    required this.chorusTransitionSeconds,
  });

  final double balanceSpeed;
  final double balanceAmplitude;
  final double bassResponse;
  final double escapementSpring;
  final double escapementDamping;
  final double chorusHaloOpacity;
  final double chorusHaloScale;
  final double chorusGlow;
  final double chorusTransitionSeconds;

  static const PendoloMotionProfile calm = PendoloMotionProfile(
    balanceSpeed: 0.72,
    balanceAmplitude: 0.58,
    bassResponse: 0.62,
    escapementSpring: 0.72,
    escapementDamping: 1.2,
    chorusHaloOpacity: 0.22,
    chorusHaloScale: 1.012,
    chorusGlow: 0.72,
    chorusTransitionSeconds: 0.52,
  );

  static const PendoloMotionProfile normal = PendoloMotionProfile(
    balanceSpeed: 1,
    balanceAmplitude: 1,
    bassResponse: 1,
    escapementSpring: 1,
    escapementDamping: 1,
    chorusHaloOpacity: 0.34,
    chorusHaloScale: 1.026,
    chorusGlow: 1,
    chorusTransitionSeconds: 0.42,
  );

  static const PendoloMotionProfile chaotic = PendoloMotionProfile(
    balanceSpeed: 1.3,
    balanceAmplitude: 1.42,
    bassResponse: 1.38,
    escapementSpring: 1.3,
    escapementDamping: 0.84,
    chorusHaloOpacity: 0.5,
    chorusHaloScale: 1.045,
    chorusGlow: 1.42,
    chorusTransitionSeconds: 0.3,
  );

  /// folia `resolvePendoloMotionProfile`：生效的动画强度 → 档位。
  static PendoloMotionProfile of(LyricVisualizerIntensity intensity) =>
      switch (intensity) {
        LyricVisualizerIntensity.calm => calm,
        LyricVisualizerIntensity.chaotic => chaotic,
        LyricVisualizerIntensity.normal => normal,
      };
}

/// folia `resolvePendoloChorusPresentation`：副歌强调只给正在唱的那一句。
class PendoloChorusLook {
  const PendoloChorusLook._({
    required this.active,
    required this.accentMix,
    required this.haloOpacity,
    required this.haloScale,
    required this.glow,
  });

  factory PendoloChorusLook.of(
    bool isChorus,
    bool playing,
    PendoloMotionProfile profile,
  ) {
    final bool active = isChorus && playing;
    return PendoloChorusLook._(
      active: active,
      accentMix: active ? 0.58 : 0.32,
      haloOpacity: active ? profile.chorusHaloOpacity : 0,
      haloScale: active ? profile.chorusHaloScale : 1,
      glow: active ? profile.chorusGlow : 0,
    );
  }

  final bool active;

  /// 扫亮色里强调色的比例（folia 0.58 / 0.32）。
  final double accentMix;
  final double haloOpacity;
  final double haloScale;
  final double glow;
}

/// 一句的副歌强调随 folia 的 transition（easeOut，时长按档位）缓入缓出：[step] 推进线性进度，
/// [eased] 是画用的缓动值。
class PendoloChorusRamp {
  double _t = 0;

  double get progress => _t;

  /// easeOut（三次）。
  double get eased => 1 - math.pow(1 - _t, 3).toDouble();

  void step(bool on, double dt, double seconds) {
    final double rate = dt / math.max(0.05, seconds);
    _t = (on ? _t + rate : _t - rate).clamp(0.0, 1.0);
  }

  bool get idle => _t <= 0;
}

// ─── 鼓面效果（folia usePendoloBeatFx 的鼓击分支） ──────────────────────────

/// folia `BEAT_FX_WEAK_BEAT_FLOOR`。
const double kPendoloWeakBeatFloor = 0.35;

/// folia `PUNCH_RANGE_DB`：重音按分贝读的跨度。
const double _kPunchRangeDb = 30;

/// folia `resolvePendoloWavePunch`：一下鼓击（强度 [accent]，0–1）按分贝曲线读成光晕 / 宝石 /
/// 表盘的亮度，乘鼓面强度 [strength]（0–2），上限 1。
double pendoloWavePunch(double accent, double strength) {
  final double a = accent.clamp(0.0, 1.0);
  if (a <= 0 || strength <= 0) return 0;
  final double below = (1 - a) / (1 - kPendoloWeakBeatFloor);
  return math.min(
    1,
    strength * math.pow(10, -(_kPunchRangeDb / 20) * below).toDouble(),
  );
}

/// 鼓击上升沿的门限：`drumImpact` 一帧里涨这么多才算新的一下（衰减中的抖动不算）。
const double _kHitRise = 0.04;

/// folia 鼓面常量。
const double _kGlowFallSeconds = 0.15;
const double _kGlowScale = 0.55;
const double _kBreath = 0.035;
const double _kBreathHz = 6;
const double _kBreathSeconds = 0.15;
const double _kShakeShare = 0.6;
const double _kShakeDecay = 9;
const double _kShakePx = 8;
const double _kFlareDecaySeconds = 0.25;
const double _kDialDecaySeconds = 0.45;

/// 鼓面效果的跨帧状态。
class PendoloDrumhead {
  double _lastImpact = 0;
  bool _primed = false;
  double _sinceSwell = 1e9;
  double _swellAmount = 0;

  /// 轮心光晕亮度（0–1，瞬间点亮、0.15 秒落下）。
  double glow = 0;
  double jewelFlare = 0;
  double tickDialLight = 0;
  double outerDialLight = 0;
  double shake = 0;

  /// 整个表盘的鼓起（1 = 不鼓）。
  double breath = 1;

  /// 光晕大小（占满屏半径的比例）。
  double get haloScale => _kGlowScale + (1 - _kGlowScale) * glow;

  bool get idle =>
      glow <= 0 &&
      jewelFlare <= 0 &&
      tickDialLight <= 0 &&
      outerDialLight <= 0 &&
      shake <= 0 &&
      breath == 1;

  /// 回到静止（换歌 / 拖进度 / 关掉效果）。
  void reset() {
    _lastImpact = 0;
    _primed = false;
    _sinceSwell = 1e9;
    _swellAmount = 0;
    glow = 0;
    jewelFlare = 0;
    tickDialLight = 0;
    outerDialLight = 0;
    shake = 0;
    breath = 1;
  }

  /// 推进一帧。[drumImpact] 是共享音频帧的鼓击冲击（0–1），[strength] 是鼓面强度（0–2）。
  /// [jump] 为 true（拖进度 / 首帧）时只对齐，不点亮。返回这一帧有没有新的一下鼓击。
  bool step(
    double dt,
    double drumImpact, {
    required double strength,
    bool jump = false,
  }) {
    final double impact = drumImpact.clamp(0.0, 1.0);
    final bool hit =
        _primed && !jump && strength > 0 && impact - _lastImpact > _kHitRise;
    _lastImpact = impact;
    _primed = true;

    glow *= math.exp(-dt / _kGlowFallSeconds);
    final double flareDecay = math.exp(-dt / _kFlareDecaySeconds * 2.3);
    jewelFlare *= flareDecay;
    final double dialDecay = math.exp(-dt / _kDialDecaySeconds * 2.3);
    tickDialLight *= dialDecay;
    outerDialLight *= dialDecay;
    shake *= math.exp(-_kShakeDecay * dt);
    _sinceSwell += dt;

    if (hit) {
      final double punch = pendoloWavePunch(impact, strength);
      glow = math.max(glow, punch);
      jewelFlare = math.max(jewelFlare, punch);
      tickDialLight = math.max(tickDialLight, punch);
      outerDialLight = math.max(outerDialLight, punch);
      // Fushi 的鼓击不分底鼓 / 军鼓：每一下都按底鼓处理（鼓起），强的一下再抖屏。
      _swellAmount = impact * strength;
      _sinceSwell = 0;
      if (impact >= _kShakeShare) {
        shake = math.max(shake, math.min(1.5, impact * strength));
      }
    }

    if (glow < 0.005) glow = 0;
    if (jewelFlare < 1e-3) jewelFlare = 0;
    if (tickDialLight < 1e-3) tickDialLight = 0;
    if (outerDialLight < 1e-3) outerDialLight = 0;
    if (shake < 0.01) shake = 0;
    final double swell =
        _swellAmount *
        math.exp(-_sinceSwell / _kBreathSeconds) *
        math.cos(2 * math.pi * _kBreathHz * _sinceSwell);
    breath = swell.abs() < 0.01 ? 1 : 1 + _kBreath * swell;
    return hit;
  }

  /// folia `resolvePendoloShake`：这一帧的抖屏位移（px）。
  Offset shakeOffset(math.Random random) {
    if (shake < 0.01) return Offset.zero;
    final double amount = _kShakePx * shake;
    return Offset(
      (random.nextDouble() - 0.5) * 2 * amount,
      (random.nextDouble() - 0.5) * 2 * amount,
    );
  }
}

// ─── 颜色（folia resolvePendoloBeatFxColor / heatPendoloBeatFxColor） ──────────

const Color _kGold = Color(0xFFF3C46B);

/// 效果色：主题强调色提到饱和度 ≥ 60%、亮度 ≥ 70%（暗底上发光）；接近灰色时用金色。
Color pendoloBeatFxColor(Color accent) {
  final HSLColor hsl = HSLColor.fromColor(accent.withValues(alpha: 1));
  if (hsl.saturation < 0.12) return _kGold;
  return hsl
      .withSaturation(math.max(hsl.saturation, 0.6))
      .withLightness(math.max(hsl.lightness, 0.7))
      .toColor();
}

/// [color] 往白推 [heat]（0–1）：火花 / 闪光的白热芯。
Color pendoloHeat(Color color, double heat) =>
    Color.lerp(color, const Color(0xFFFFFFFF), heat.clamp(0.0, 1.0))!;

// ─── 绘制 ──────────────────────────────────────────────────────────────────

/// folia `PENDOLO_HALO_ALPHA`：光晕前沿的峰值不透明度（叠加）。
const double _kHaloAlpha = 0.45;
const double _kTickDial = 1.15;
const double _kOuterDial = 1.4;
const double _kDialGlowWidth = 10;

/// folia `resolvePendoloWaveReach`：光晕能到的最远处（越过视口最远的角）。
double pendoloWaveReach(double hubX, double hubY, Size size) =>
    math.sqrt(
      math.pow(math.max(hubX, size.width - hubX), 2) +
          math.pow(math.max(hubY, size.height - hubY), 2),
    ) *
    1.05;

/// 轮心光晕：只有前沿一圈软光，内部是空的（folia 的 radial-gradient closest-side）。画在表盘
/// 平面坐标里（原点 = 轮心），[reach] 是满尺寸半径。
void paintPendoloDrumHalo(
  Canvas canvas,
  PendoloDrumhead fx,
  double reach,
  Color color,
) {
  if (fx.glow <= 0) return;
  final double r = reach * fx.haloScale;
  if (r <= 0) return;
  Color at(double a) => color.withValues(alpha: a * fx.glow);
  canvas.drawCircle(
    Offset.zero,
    r,
    Paint()
      ..blendMode = BlendMode.plus
      ..shader = RadialGradient(
        colors: <Color>[
          at(0),
          at(0),
          at(_kHaloAlpha * 0.15),
          at(_kHaloAlpha),
          at(0),
        ],
        stops: const <double>[0, 0.45, 0.65, 0.88, 1],
      ).createShader(Rect.fromCircle(center: Offset.zero, radius: r)),
  );
}

/// 一颗会闪的宝石轴承（表盘平面坐标、所在层的高度）。
class PendoloJewel {
  const PendoloJewel(
    this.x,
    this.y, {
    required this.small,
    required this.height,
  });

  final double x;
  final double y;
  final bool small;
  final double height;
}

/// folia `resolveJewels`：轮心与摆轮是大的，传动轮 / 秒齿轮 / 惰轮 / 三颗行星轮是小的。
List<PendoloJewel> pendoloJewels(
  PendoloClockworkAnchors an,
  double escapementAngle,
) => <PendoloJewel>[
  const PendoloJewel(0, 0, small: false, height: PendoloLayerHeight.mainSun),
  PendoloJewel(
    an.balanceX,
    an.balanceY,
    small: false,
    height: PendoloLayerHeight.balance,
  ),
  PendoloJewel(
    an.transX,
    an.transY,
    small: true,
    height: PendoloLayerHeight.trans,
  ),
  PendoloJewel(
    an.secondX,
    an.secondY,
    small: true,
    height: PendoloLayerHeight.second,
  ),
  PendoloJewel(
    an.idlerX,
    an.idlerY,
    small: true,
    height: PendoloLayerHeight.idler,
  ),
  for (int i = 0; i < 3; i++)
    PendoloJewel(
      an.orbitR * math.cos(escapementAngle * 0.4 + i * math.pi * 2 / 3),
      an.orbitR * math.sin(escapementAngle * 0.4 + i * math.pi * 2 / 3),
      small: true,
      height: PendoloLayerHeight.planet,
    ),
];

/// folia `flareRadius`。
double pendoloFlareRadius(double flare, bool small) =>
    (small ? 26 : 40) * (0.6 + math.min(1.5, flare));

/// 亮起的刻度圈与外圈（表盘平面坐标，原点 = 轮心；叠加混合）。
void paintPendoloDialLights(
  Canvas canvas,
  PendoloDrumhead fx,
  double baseRadius,
  double escapementAngle,
  Color color,
) {
  final Paint p = Paint()
    ..style = PaintingStyle.stroke
    ..blendMode = BlendMode.plus;
  final double tick = fx.tickDialLight;
  if (tick > 0) {
    final double outerTickR = baseRadius * _kTickDial;
    p
      ..color = pendoloHeat(
        color,
        0.25 * tick,
      ).withValues(alpha: (0.35 + 0.65 * tick).clamp(0.0, 1.0))
      ..strokeWidth = 1.5 + 2.5 * tick;
    final Float32List pts = Float32List(60 * 4);
    for (int i = 0; i < 60; i++) {
      final double a = i * math.pi * 2 / 60 + escapementAngle * 0.2;
      final double len = i % 5 == 0 ? 12 : 6;
      final double c = math.cos(a);
      final double s = math.sin(a);
      pts[i * 4] = outerTickR * c;
      pts[i * 4 + 1] = outerTickR * s;
      pts[i * 4 + 2] = (outerTickR + len) * c;
      pts[i * 4 + 3] = (outerTickR + len) * s;
    }
    canvas.drawRawPoints(ui.PointMode.lines, pts, p);
  }
  void ring(double r, double light) {
    p
      ..color = color.withValues(alpha: 0.22 * light)
      ..strokeWidth = _kDialGlowWidth;
    canvas.drawCircle(Offset.zero, r, p);
    p
      ..color = pendoloHeat(color, 0.3 * light).withValues(alpha: light)
      ..strokeWidth = 1.5 + 1.5 * light;
    canvas.drawCircle(Offset.zero, r, p);
  }

  if (tick > 0) ring(baseRadius * _kTickDial, tick);
  if (fx.outerDialLight > 0) {
    ring(baseRadius * _kOuterDial, fx.outerDialLight);
  }
}

/// 一颗宝石的闪光（以宝石为原点；径向 (1 − r)² 衰减，叠加混合）。
void paintPendoloJewelFlare(
  Canvas canvas,
  double flare,
  bool small,
  Color color,
) {
  if (flare <= 0.01) return;
  final double r = pendoloFlareRadius(flare, small);
  final Color hot = pendoloHeat(color, 0.6);
  final double a = math.min(1, flare);
  canvas.drawCircle(
    Offset.zero,
    r,
    Paint()
      ..blendMode = BlendMode.plus
      ..shader = RadialGradient(
        colors: <Color>[
          hot.withValues(alpha: a),
          hot.withValues(alpha: a * 0.25),
          hot.withValues(alpha: 0),
        ],
        stops: const <double>[0, 0.5, 1],
      ).createShader(Rect.fromCircle(center: Offset.zero, radius: r)),
  );
}
