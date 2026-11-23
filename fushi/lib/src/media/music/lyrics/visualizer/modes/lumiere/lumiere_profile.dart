/// 绘光的光位（镜头风格）profile 与各族共用的积木（folia `lumiere/types.ts` + `rigs/base.ts`）。
/// 一个光位 = 光束组 + 烟雾 + 浮尘 + 前景散景 + 线稿配方 + 文字区 + 运镜，全是数据，由同一套场景解释。
library;

import 'dart:math' as math;

import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_line_art.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_math.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_rig.dart';

enum LumiereMood { quiet, neutral, loud }

/// horizontal 横排为主；vertical 竖排为主（右起）；crossed 当前行横排、周围的行自由落点。
enum WindowTypography { horizontal, vertical, crossed }

class RigContext {
  const RigContext(this.aspect, this.random);
  final double aspect;
  final LumiereRng random;
}

class DecaySpec {
  const DecaySpec(this.strength, this.delay);
  final double strength;
  final double delay;
}

enum BurstMode { sung, sweep }

/// 十字爆闪（EVA 式，行内一串小十字）。
class BurstSpec {
  const BurstSpec(
    this.mode,
    this.density,
    this.every,
    this.offset,
    this.size,
    this.tint,
  );
  final BurstMode mode;
  final double density;
  final int every;
  final int offset;
  final double size;
  final Rgb tint;
}

class MotesSpec {
  const MotesSpec({
    this.count = 260,
    this.sizeMin = 0.004,
    this.sizeMax = 0.013,
    this.driftX = 0.004,
    this.driftY = -0.01,
    this.swirl = 0.02,
    this.swirlPeriod = 9,
    this.twinkle = 0.5,
    this.ambient = 0.015,
    this.gain = 1.3,
  });
  final int count;
  final double sizeMin;
  final double sizeMax;
  final double driftX;
  final double driftY;
  final double swirl;
  final double swirlPeriod;
  final double twinkle;
  final double ambient;
  final double gain;

  MotesSpec copyWith({
    int? count,
    double? sizeMin,
    double? sizeMax,
    double? driftX,
    double? driftY,
    double? swirl,
    double? swirlPeriod,
    double? twinkle,
    double? ambient,
    double? gain,
  }) => MotesSpec(
    count: count ?? this.count,
    sizeMin: sizeMin ?? this.sizeMin,
    sizeMax: sizeMax ?? this.sizeMax,
    driftX: driftX ?? this.driftX,
    driftY: driftY ?? this.driftY,
    swirl: swirl ?? this.swirl,
    swirlPeriod: swirlPeriod ?? this.swirlPeriod,
    twinkle: twinkle ?? this.twinkle,
    ambient: ambient ?? this.ambient,
    gain: gain ?? this.gain,
  );
}

/// 星空点亮（开场光点倾泻 + 星空 + 光雨）。
class StarfallSpec {
  const StarfallSpec({
    this.stars = 420,
    this.opening = 3.2,
    this.rain = 70,
    this.rainSpeed = 0.22,
    this.rainSpread = 0.35,
    this.brightness = 1,
  });
  final int stars;
  final double opening;
  final int rain;
  final double rainSpeed;
  final double rainSpread;
  final double brightness;

  StarfallSpec copyWith({
    int? stars,
    double? opening,
    int? rain,
    double? rainSpeed,
    double? rainSpread,
    double? brightness,
  }) => StarfallSpec(
    stars: stars ?? this.stars,
    opening: opening ?? this.opening,
    rain: rain ?? this.rain,
    rainSpeed: rainSpeed ?? this.rainSpeed,
    rainSpread: rainSpread ?? this.rainSpread,
    brightness: brightness ?? this.brightness,
  );
}

/// 主光柱在开场的什么时刻点亮（相对镜头开始，秒）。
double starfallIgnition(StarfallSpec s) => s.opening * 0.45;

/// 文字区（画面比例，中心 + 宽高）。
class TextRegion {
  const TextRegion(this.cx, this.cy, this.w, this.h);
  final double cx;
  final double cy;
  final double w;
  final double h;
}

class CameraSpec {
  const CameraSpec(this.push, this.driftX, this.driftY);
  final double push;
  final double driftX;
  final double driftY;
}

typedef RigBuilder = LightRig Function(RigContext context);
typedef ArtBuilder = LineArtSpec Function(RigContext context);

class LumiereProfile {
  const LumiereProfile({
    required this.kind,
    required this.label,
    required this.family,
    required this.mood,
    required this.light,
    required this.motes,
    required this.front,
    required this.lineArt,
    required this.region,
    required this.heroSize,
    required this.typography,
    required this.decay,
    required this.camera,
    this.burst,
    this.starfall,
    this.echoSize = 0.34,
    this.artGain = 1,
  });

  final String kind;
  final String label;
  final String family;
  final LumiereMood mood;
  final RigBuilder light;
  final MotesSpec motes;
  final MotesSpec? front;
  final ArtBuilder lineArt;
  final TextRegion region;

  /// 当前行字号（占画面高度）。
  final double heroSize;
  final WindowTypography typography;
  final DecaySpec decay;
  final CameraSpec camera;
  final BurstSpec? burst;
  final StarfallSpec? starfall;

  /// 背景歌词碎片的最大字号（占画面高度）。
  final double echoSize;
  final double artGain;
}

// ---------------------------------------------------------------------------
// rigs/base.ts
// ---------------------------------------------------------------------------

const double kDown = math.pi / 2;

/// 主光柱：窄、亮、束内有一丝丝的亮纹。
const BeamSpec kShaft = BeamSpec(
  x: 0.5,
  y: -0.04,
  angle: kDown,
  spread: 0.09,
  width: 0.05,
  length: 0.8,
  softness: 0.6,
  intensity: 0.95,
  streaks: 0.6,
  streakFreq: 7,
  streakSpeed: 0.08,
  core: 0.75,
  sway: Oscillation(0.012, 13, 0),
);

/// 主光柱外的一圈放射光扇。
const BeamSpec kFan = BeamSpec(
  x: 0.5,
  y: -0.04,
  angle: kDown,
  spread: 0.3,
  length: 0.6,
  softness: 0.9,
  intensity: 0.32,
  streaks: 0.85,
  streakFreq: 26,
  streakSpeed: 0.05,
  core: 0.4,
  sway: Oscillation(0.02, 17, 0.3),
);

const FogSpec kFog = FogSpec();
const GlareSpec kGlare = GlareSpec();
const MotesSpec kMotes = MotesSpec();
const MotesSpec kFront = MotesSpec(
  count: 9,
  sizeMin: 0.05,
  sizeMax: 0.15,
  driftX: 0.006,
  driftY: -0.002,
  swirl: 0.012,
  swirlPeriod: 14,
  twinkle: 0.2,
  ambient: 0.02,
  gain: 0.3,
);
const StarfallSpec kStarfall = StarfallSpec();
const TextRegion kRegion = TextRegion(0.5, 0.54, 0.72, 0.5);
const CameraSpec kCamera = CameraSpec(0.035, 0, -0.006);

/// 量角器光环 + 取景框 + 散落闪点（参考图的线稿）。
LineArtSpec standardArt(
  RigContext c, [
  double haloRadius = 0.3,
]) => mergeArt(<LineArtSpec>[
  protractorHalo(cx: c.aspect * 0.5, cy: 0.03, radius: haloRadius, alpha: 0.55),
  viewfinderFrame(
    aspect: c.aspect,
    left: 0.07,
    top: 0.21,
    right: 0.93,
    bottom: 0.8,
    delay: 0.1,
    alpha: 0.32,
  ),
  scatteredSparks(aspect: c.aspect, count: 16, random: c.random, delay: 0.3),
]);

/// 只有取景框与闪点。
LineArtSpec frameArt(RigContext c) => mergeArt(<LineArtSpec>[
  viewfinderFrame(
    aspect: c.aspect,
    left: 0.07,
    top: 0.21,
    right: 0.93,
    bottom: 0.8,
    delay: 0.1,
    alpha: 0.28,
  ),
  scatteredSparks(aspect: c.aspect, count: 14, random: c.random, delay: 0.3),
]);

List<Pt> ellipsePts(double cx, double cy, double rx, double ry) =>
    ellipsePath(cx, cy, rx, ry);

/// 光位构造：光束 + 烟雾 + 眩光 + 焦散 / 干涉。
RigBuilder rig(
  List<BeamSpec> beams, {
  FogSpec fog = kFog,
  GlareSpec? glare = kGlare,
  CausticSpec? caustic,
  WaveSpec? wave,
}) =>
    (RigContext _) => LightRig(
      beams: beams,
      fog: fog,
      glare: glare,
      caustic: caustic,
      wave: wave,
    );

/// 按族填默认值的光位构造器：各光位只写不同的地方。
class LumiereFamily {
  const LumiereFamily(
    this.name, {
    this.motes = kMotes,
    this.front = kFront,
    this.lineArt = standardArt,
    this.region = kRegion,
    this.heroSize = 0.085,
    this.camera = kCamera,
    this.starfall,
    this.artGain = 1,
  });

  final String name;
  final MotesSpec motes;
  final MotesSpec? front;
  final ArtBuilder lineArt;
  final TextRegion region;
  final double heroSize;
  final CameraSpec camera;
  final StarfallSpec? starfall;
  final double artGain;

  LumiereProfile call({
    required String kind,
    required String label,
    required LumiereMood mood,
    required RigBuilder light,
    required WindowTypography typography,
    required DecaySpec decay,
    ArtBuilder? lineArt,
    TextRegion? region,
    double? heroSize,
    CameraSpec? camera,
    MotesSpec? motes,
    MotesSpec? front,
    BurstSpec? burst,
    StarfallSpec? starfall,
    double? artGain,
  }) => LumiereProfile(
    kind: kind,
    label: label,
    family: name,
    mood: mood,
    light: light,
    motes: motes ?? this.motes,
    front: front ?? this.front,
    lineArt: lineArt ?? this.lineArt,
    region: region ?? this.region,
    heroSize: heroSize ?? this.heroSize,
    typography: typography,
    decay: decay,
    camera: camera ?? this.camera,
    burst: burst,
    starfall: starfall ?? this.starfall,
    artGain: artGain ?? this.artGain,
  );
}
