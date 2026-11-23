/// 光位（rig）：一个镜头的光束、烟雾、光源眩光、焦散、干涉的声明式描述，以及光束强度的 CPU 算法
/// （folia `lumiere/light/rig.ts`）。字、浮尘、线稿的亮度与光场画面用同一个公式：光柱扫到哪里，哪里的字就亮。
///
/// 坐标：一律「以画面高度为 1」的单位（u = 像素 / 高度），y 向下；角度 0 = 向右，π/2 = 向下。
/// 声明里的位置用画面比例（x 占宽、y 占高），解析时换算。
library;

import 'dart:math' as math;

import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_math.dart';

const int kMaxBeams = 6;

class Oscillation {
  const Oscillation(this.amplitude, this.period, this.phase);
  final double amplitude;
  final double period;
  final double phase;
}

/// 窗影图样：blinds 平行光带、cross 窗棂、lattice 菱格、leaves 叶隙。
enum GoboPattern { blinds, cross, lattice, leaves }

class GoboSpec {
  const GoboSpec(this.pattern, this.frequency, this.duty, this.drift);
  final GoboPattern pattern;
  final double frequency;
  final double duty;
  final double drift;
}

class BeamSpec {
  const BeamSpec({
    required this.x,
    required this.y,
    required this.angle,
    required this.spread,
    this.width = 0,
    required this.length,
    required this.softness,
    required this.intensity,
    required this.streaks,
    required this.streakFreq,
    required this.streakSpeed,
    this.core = 0.5,
    this.sway,
    this.pulse,
    this.tint = kWhite,
    this.reveal,
    this.gobo,
    this.spectrum = 0,
    this.reach = 0,
  });

  final double x;
  final double y;
  final double angle;

  /// 半张角（弧度）；负数为会聚（沙漏形）。
  final double spread;
  final double width;
  final double length;
  final double softness;
  final double intensity;
  final double streaks;
  final double streakFreq;
  final double streakSpeed;
  final double core;
  final Oscillation? sway;
  final Oscillation? pulse;
  final Rgb tint;
  final double? reveal;
  final GoboSpec? gobo;
  final double spectrum;

  /// 射程（高度单位），0 = 一直延伸。
  final double reach;

  BeamSpec copyWith({
    double? x,
    double? y,
    double? angle,
    double? spread,
    double? width,
    double? length,
    double? softness,
    double? intensity,
    double? streaks,
    double? streakFreq,
    double? streakSpeed,
    double? core,
    Oscillation? sway,
    bool noSway = false,
    Oscillation? pulse,
    Rgb? tint,
    double? reveal,
    GoboSpec? gobo,
    double? spectrum,
    double? reach,
  }) => BeamSpec(
    x: x ?? this.x,
    y: y ?? this.y,
    angle: angle ?? this.angle,
    spread: spread ?? this.spread,
    width: width ?? this.width,
    length: length ?? this.length,
    softness: softness ?? this.softness,
    intensity: intensity ?? this.intensity,
    streaks: streaks ?? this.streaks,
    streakFreq: streakFreq ?? this.streakFreq,
    streakSpeed: streakSpeed ?? this.streakSpeed,
    core: core ?? this.core,
    sway: noSway ? null : (sway ?? this.sway),
    pulse: pulse ?? this.pulse,
    tint: tint ?? this.tint,
    reveal: reveal ?? this.reveal,
    gobo: gobo ?? this.gobo,
    spectrum: spectrum ?? this.spectrum,
    reach: reach ?? this.reach,
  );
}

class CausticFloor {
  const CausticFloor(this.cx, this.cy, this.rx, this.ry, this.strength);
  final double cx;
  final double cy;
  final double rx;
  final double ry;
  final double strength;
}

class CausticSpec {
  const CausticSpec({
    this.scale = 2.2,
    this.speed = 0.35,
    this.inBeam = 0.8,
    this.floor,
  });
  final double scale;
  final double speed;
  final double inBeam;
  final CausticFloor? floor;

  CausticSpec faded(double k) => CausticSpec(
    scale: scale,
    speed: speed,
    inBeam: inBeam * k,
    floor: floor == null
        ? null
        : CausticFloor(
            floor!.cx,
            floor!.cy,
            floor!.rx,
            floor!.ry,
            floor!.strength * k,
          ),
  );
}

enum WaveMode { rings, slits, sources, airy }

class WaveSpec {
  const WaveSpec({
    required this.mode,
    required this.cx,
    required this.cy,
    required this.radius,
    required this.frequency,
    required this.speed,
    required this.strength,
    this.separation = 0,
    this.shield = 0.45,
  });
  final WaveMode mode;
  final double cx;
  final double cy;
  final double radius;
  final double frequency;
  final double speed;
  final double strength;
  final double separation;
  final double shield;

  WaveSpec withStrength(double s) => WaveSpec(
    mode: mode,
    cx: cx,
    cy: cy,
    radius: radius,
    frequency: frequency,
    speed: speed,
    strength: s,
    separation: separation,
    shield: shield,
  );
}

class FogSpec {
  const FogSpec({
    this.density = 1,
    this.tyndallBase = 0.12,
    this.scale = 2.4,
    this.driftX = 0.008,
    this.driftY = -0.04,
    this.warp = 0.9,
    this.ambient = 0.03,
  });
  final double density;
  final double tyndallBase;
  final double scale;
  final double driftX;
  final double driftY;
  final double warp;
  final double ambient;

  FogSpec copyWith({
    double? density,
    double? tyndallBase,
    double? scale,
    double? driftX,
    double? driftY,
    double? warp,
    double? ambient,
  }) => FogSpec(
    density: density ?? this.density,
    tyndallBase: tyndallBase ?? this.tyndallBase,
    scale: scale ?? this.scale,
    driftX: driftX ?? this.driftX,
    driftY: driftY ?? this.driftY,
    warp: warp ?? this.warp,
    ambient: ambient ?? this.ambient,
  );

  static FogSpec lerp(FogSpec a, FogSpec b, double k) => FogSpec(
    density: lerpD(a.density, b.density, k),
    tyndallBase: lerpD(a.tyndallBase, b.tyndallBase, k),
    scale: lerpD(a.scale, b.scale, k),
    driftX: lerpD(a.driftX, b.driftX, k),
    driftY: lerpD(a.driftY, b.driftY, k),
    warp: lerpD(a.warp, b.warp, k),
    ambient: lerpD(a.ambient, b.ambient, k),
  );
}

class GlareSpec {
  const GlareSpec({
    this.x = 0.5,
    this.y = 0,
    this.radius = 0.12,
    this.intensity = 0.9,
    this.streak = 0.45,
  });
  final double x;
  final double y;
  final double radius;
  final double intensity;
  final double streak;

  GlareSpec copyWith({
    double? x,
    double? y,
    double? radius,
    double? intensity,
    double? streak,
  }) => GlareSpec(
    x: x ?? this.x,
    y: y ?? this.y,
    radius: radius ?? this.radius,
    intensity: intensity ?? this.intensity,
    streak: streak ?? this.streak,
  );
}

class LightRig {
  const LightRig({
    required this.beams,
    this.fog = const FogSpec(),
    this.glare,
    this.caustic,
    this.wave,
  });
  final List<BeamSpec> beams;
  final FogSpec fog;
  final GlareSpec? glare;
  final CausticSpec? caustic;
  final WaveSpec? wave;
}

/// 解析到某一时刻、换算到高度单位的光束。
class ResolvedBeam {
  const ResolvedBeam({
    required this.ox,
    required this.oy,
    required this.dx,
    required this.dy,
    required this.halfWidth,
    required this.tanSpread,
    required this.softness,
    required this.length,
    required this.intensity,
    required this.streaks,
    required this.streakFreq,
    required this.streakPhase,
    required this.core,
    required this.color,
    required this.gobo,
    required this.goboPhase,
    required this.spectrum,
    required this.reach,
  });
  final double ox;
  final double oy;
  final double dx;
  final double dy;
  final double halfWidth;
  final double tanSpread;
  final double softness;
  final double length;
  final double intensity;
  final double streaks;
  final double streakFreq;
  final double streakPhase;
  final double core;
  final Rgb color;
  final GoboSpec? gobo;
  final double goboPhase;
  final double spectrum;
  final double reach;

  ResolvedBeam withIntensity(double v) => ResolvedBeam(
    ox: ox,
    oy: oy,
    dx: dx,
    dy: dy,
    halfWidth: halfWidth,
    tanSpread: tanSpread,
    softness: softness,
    length: length,
    intensity: v,
    streaks: streaks,
    streakFreq: streakFreq,
    streakPhase: streakPhase,
    core: core,
    color: color,
    gobo: gobo,
    goboPhase: goboPhase,
    spectrum: spectrum,
    reach: reach,
  );
}

/// 一帧驱动光位的量：整体亮度、音频低频（已乘过响应）、光色、镜头开始后的秒数。
class LightDrive {
  const LightDrive({
    required this.intensity,
    required this.bass,
    required this.color,
    this.local,
  });
  final double intensity;
  final double bass;
  final Rgb color;
  final double? local;
}

/// 低频 → 光束亮度倍率：低频打满时亮 15%，取 1.5 次方。
double audioLift(double bass) =>
    1 + 0.15 * math.pow(math.max(0, bass), 1.5).toDouble();

double _osc(Oscillation? o, double time) => o == null
    ? 0
    : o.amplitude *
          math.sin((time / math.max(o.period, 0.001) + o.phase) * kTau);

List<ResolvedBeam> resolveBeams(
  LightRig rig,
  double time,
  double aspect,
  LightDrive drive,
) {
  final List<ResolvedBeam> out = <ResolvedBeam>[];
  for (final BeamSpec beam in rig.beams.take(kMaxBeams)) {
    final double angle = beam.angle + _osc(beam.sway, time);
    final double pulse = 1 + _osc(beam.pulse, time);
    final double reveal = beam.reveal != null && drive.local != null
        ? 0.06 + 0.94 * smoothstep(0, 1, drive.local! / beam.reveal!)
        : 1;
    out.add(
      ResolvedBeam(
        ox: beam.x * aspect,
        oy: beam.y,
        dx: math.cos(angle),
        dy: math.sin(angle),
        halfWidth: beam.width / 2,
        tanSpread: math.tan(beam.spread),
        softness: beam.softness,
        length: beam.length * reveal,
        intensity:
            beam.intensity * pulse * drive.intensity * audioLift(drive.bass),
        streaks: beam.streaks,
        streakFreq: beam.streakFreq,
        streakPhase: time * beam.streakSpeed,
        core: beam.core,
        color: beam.tint.times(drive.color),
        gobo: beam.gobo,
        goboPhase: (beam.gobo?.drift ?? 0) * time,
        spectrum: beam.spectrum,
        reach: beam.reach,
      ),
    );
  }
  return out;
}

double _band(double x, double duty) {
  final double f = fract(x);
  return 1 - smoothstep(duty - 0.06, duty + 0.06, f) + smoothstep(0.94, 1, f);
}

/// 窗影的影子里仍透过的散射光。
const double kGoboLeak = 0.12;

double goboMask(GoboSpec? gobo, double phase, double u, double v) {
  if (gobo == null) return 1;
  final double f = gobo.frequency;
  final double d = gobo.duty;
  final double p = switch (gobo.pattern) {
    GoboPattern.blinds => math.min(1.0, _band(u * f * 0.5 + phase, d)),
    GoboPattern.cross => smoothstep(d * 0.5, d * 0.5 + 0.08, u.abs()),
    GoboPattern.lattice =>
      math.min(1.0, _band(u * f * 0.5 + v * f * 0.8 + phase, d)) *
          math.min(1.0, _band(u * f * 0.5 - v * f * 0.8 - phase, d)),
    GoboPattern.leaves => smoothstep(
      d - 0.12,
      d + 0.12,
      valueNoise2(u * f, v * f * 0.6 + phase),
    ),
  };
  return kGoboLeak + (1 - kGoboLeak) * p;
}

/// 截面坐标 (s 带符号, along) 处一束光的强度——[beamMask] 去掉坐标换算的那一半，光束网格直接用。
double beamMaskAt(ResolvedBeam beam, double signedS, double along) {
  if (along <= 0) return 0;
  final double s = signedS.abs();
  final double half = (beam.halfWidth + along * beam.tanSpread).abs() + 1e-4;
  final double edge = smoothstep(1, 1 - math.max(beam.softness, 0.02), s);
  if (edge <= 0) return 0;
  final double streak =
      1 -
      beam.streaks +
      beam.streaks * valueNoise1(signedS * beam.streakFreq + beam.streakPhase);
  final double core = 1 - beam.core + beam.core * (1 - s * s);
  final double falloff = math.exp(-along / math.max(beam.length, 0.001));
  final double gobo = goboMask(beam.gobo, beam.goboPhase, signedS, along);
  final double reach = beam.reach > 0
      ? 1 -
            smoothstep(
              beam.reach - math.max(0.04, half * 2.5),
              beam.reach,
              along,
            )
      : 1;
  final double start = smoothstep(0, beam.halfWidth.abs() * 2 + 0.01, along);
  return edge * streak * core * falloff * gobo * reach * start * beam.intensity;
}

/// 一束光在点 (x, y)（高度单位）处的强度（不含烟雾与颜色）。
double beamMask(ResolvedBeam beam, double x, double y) {
  final double px = x - beam.ox;
  final double py = y - beam.oy;
  final double along = px * beam.dx + py * beam.dy;
  if (along <= 0) return 0;
  final double perp = px * -beam.dy + py * beam.dx;
  final double half = (beam.halfWidth + along * beam.tanSpread).abs() + 1e-4;
  final double s = perp / half;
  if (s.abs() >= 1) return 0;
  return beamMaskAt(beam, s, along);
}

double lightAt(List<ResolvedBeam> beams, double x, double y) {
  double sum = 0;
  for (final ResolvedBeam b in beams) {
    sum += beamMask(b, x, y);
  }
  return sum;
}

/// 柔和压缩，避免交叠处爆白。
double compressLight(double v) => 1 - math.exp(-v);

/// 色散：截面横向位置 → 光谱色。
Rgb spectrumColor(double u) {
  final double h = clamp01(0.5 + 0.5 * u) * 0.8;
  double k(double o) => clamp01((fract(h + o) * 6 - 3).abs() - 1);
  return kWhite.mix(Rgb(k(0), k(2 / 3), k(1 / 3)), 0.85);
}
