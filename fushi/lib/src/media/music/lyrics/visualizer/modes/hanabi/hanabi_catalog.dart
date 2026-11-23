/// 花火的共享类型与预设目录（移植 folia `hanabi/types.ts` + `catalog.ts`）：
/// 10 族 × 5 = 50 个镜头风格，全是数据，由同一个场景解释。
library;

/// 预设的情绪（编译时按段落性质挑）。
enum HanabiMood { quiet, neutral, loud }

/// 行在文字区里的摆法。
enum TextLayoutKind {
  center,
  left,
  right,
  stagger,
  diagonal,
  scatter,
  vertical,
  verticalSplit,
  arc,
}

/// 字底色块。
enum BlockStyle {
  none,
  tile,
  band,
  slant,
  double,
  pill,
  split,
  ticket,
  marker,
  outline,
  circle,
  stair,
}

/// 入场动画（逐字）。
enum EnterFx {
  pop,
  drop,
  rise,
  spin,
  wipe,
  type,
  scramble,
  stretch,
  elastic,
  split,
  spiral,
  flip,
  glitch,
  stamp,
  wave,
  zoom,
  burst,
}

/// 被唱到时的强调。
enum SingFx { none, bounce, flash, swell, shake, jump, glow, underline, color }

/// 退场。
enum ExitFx { ascend, scatter, shrink, slide, dissolve, fall, blink }

/// 烟花的种类（日本花火的分类）。
enum BurstKind {
  kiku,
  botan,
  yanagi,
  kamuro,
  senrin,
  ring,
  heart,
  star,
  palm,
  crossette,
  strobe,
  hachi,
  willowRing,
  mine,
}

enum OrnamentKind {
  ring,
  spokes,
  sparkle,
  orbit,
  chevrons,
  brackets,
  cross,
  zigzag,
  wave,
  halftone,
  confetti,
  shards,
  dashCircle,
  squares,
  streaks,
  petals,
  stamp,
  rays,
  underline,
  dotsLine,
  glints,
}

enum OrnamentPlacement {
  glyphs,
  around,
  behind,
  corners,
  lineStart,
  lineEnd,
  screen,
}

enum OrnamentColor { spark, accent, block, paper, glow }

enum OrnamentLayer { back, front }

enum PaletteRole {
  night,
  festival,
  pastel,
  mono,
  gold,
  neon,
  sakura,
  ocean,
  kawaii,
}

enum BurstAt { behind, above, sides, sky }

class TextSpec {
  const TextSpec({
    required this.layout,
    required this.heroSize,
    required this.emphasis,
    required this.tilt,
    required this.block,
    required this.enter,
    required this.sing,
    required this.exit,
    required this.stagger,
    required this.outline,
    required this.hardShadow,
  });

  final TextLayoutKind layout;

  /// 主字号（占画面短边的比例）。
  final double heroSize;

  /// 词之间字号的起伏（0..1）。
  final double emphasis;

  /// 整组倾斜（弧度）。
  final double tilt;
  final BlockStyle block;
  final EnterFx enter;
  final SingFx sing;
  final ExitFx exit;

  /// 逐字入场间隔（秒）。
  final double stagger;
  final bool outline;
  final bool hardShadow;

  TextSpec copyWith({double? heroSize}) => TextSpec(
    layout: layout,
    heroSize: heroSize ?? this.heroSize,
    emphasis: emphasis,
    tilt: tilt,
    block: block,
    enter: enter,
    sing: sing,
    exit: exit,
    stagger: stagger,
    outline: outline,
    hardShadow: hardShadow,
  );
}

class BurstSpec {
  const BurstSpec({
    required this.kind,
    required this.count,
    required this.radius,
    required this.duration,
    required this.colors,
    required this.trail,
    required this.twinkle,
  });

  final BurstKind kind;

  /// 粒子数（tuning.sparkAmount 再乘）。
  final int count;

  /// 半径（占画面短边的比例）。
  final double radius;

  /// 从开花到完全熄灭（秒）。
  final double duration;

  /// 调色板 sparks 的下标（循环取）。
  final List<int> colors;
  final double trail;
  final double twinkle;

  BurstSpec copyWith({
    int? count,
    double? radius,
    double? duration,
    List<int>? colors,
    double? trail,
    double? twinkle,
  }) => BurstSpec(
    kind: kind,
    count: count ?? this.count,
    radius: radius ?? this.radius,
    duration: duration ?? this.duration,
    colors: colors ?? this.colors,
    trail: trail ?? this.trail,
    twinkle: twinkle ?? this.twinkle,
  );
}

class OrnamentSpec {
  const OrnamentSpec({
    required this.kind,
    required this.placement,
    required this.layer,
    this.density = 0.6,
    this.scale = 1,
    this.color = OrnamentColor.accent,
    this.delay = 0,
  });

  final OrnamentKind kind;
  final OrnamentPlacement placement;
  final OrnamentLayer layer;
  final double density;
  final double scale;
  final OrnamentColor color;

  /// 相对文字入场的延迟（秒，可为负）。
  final double delay;
}

/// 文字区（画面比例，中心 + 宽高）。
class HanabiRegion {
  const HanabiRegion(this.cx, this.cy, this.w, this.h);
  final double cx;
  final double cy;
  final double w;
  final double h;
}

class HanabiCamera {
  const HanabiCamera({
    required this.rise,
    required this.push,
    required this.roll,
    required this.punch,
  });

  /// 镜头边界处世界上升的距离（占画面高度）。
  final double rise;
  final double push;
  final double roll;
  final double punch;

  HanabiCamera merge({
    double? rise,
    double? push,
    double? roll,
    double? punch,
  }) => HanabiCamera(
    rise: rise ?? this.rise,
    push: push ?? this.push,
    roll: roll ?? this.roll,
    punch: punch ?? this.punch,
  );
}

class HanabiProfile {
  const HanabiProfile({
    required this.kind,
    required this.label,
    required this.family,
    required this.mood,
    required this.text,
    required this.region,
    required this.burst,
    required this.burstAt,
    required this.sungBurst,
    required this.ornaments,
    required this.launch,
    required this.palette,
    required this.camera,
  });

  final String kind;
  final String label;
  final String family;
  final HanabiMood mood;
  final TextSpec text;
  final HanabiRegion region;
  final BurstSpec? burst;
  final BurstAt burstAt;
  final BurstSpec? sungBurst;
  final List<OrnamentSpec> ornaments;
  final bool launch;
  final PaletteRole palette;
  final HanabiCamera camera;
}

// ─── 零件 ──────────────────────────────────────────────────────────────

class _BurstBase {
  const _BurstBase(
    this.count,
    this.radius,
    this.duration,
    this.trail,
    this.twinkle,
  );
  final int count;
  final double radius;
  final double duration;
  final double trail;
  final double twinkle;
}

const Map<BurstKind, _BurstBase> _burstPresets = <BurstKind, _BurstBase>{
  BurstKind.kiku: _BurstBase(96, 0.3, 1.9, 0.65, 0.2),
  BurstKind.botan: _BurstBase(84, 0.26, 1.4, 0.1, 0.1),
  BurstKind.yanagi: _BurstBase(64, 0.3, 3.2, 0.9, 0.3),
  BurstKind.kamuro: _BurstBase(110, 0.36, 3.6, 0.95, 0.55),
  BurstKind.senrin: _BurstBase(72, 0.22, 1.7, 0.3, 0.45),
  BurstKind.ring: _BurstBase(60, 0.26, 1.4, 0.3, 0.1),
  BurstKind.heart: _BurstBase(60, 0.2, 1.6, 0.2, 0.2),
  BurstKind.star: _BurstBase(55, 0.2, 1.6, 0.2, 0.3),
  BurstKind.palm: _BurstBase(36, 0.32, 2.3, 0.8, 0.1),
  BurstKind.crossette: _BurstBase(40, 0.26, 1.9, 0.4, 0.2),
  BurstKind.strobe: _BurstBase(72, 0.28, 2.3, 0.15, 1),
  BurstKind.hachi: _BurstBase(50, 0.24, 1.6, 0.6, 0.5),
  BurstKind.willowRing: _BurstBase(100, 0.34, 2.8, 0.7, 0.3),
  BurstKind.mine: _BurstBase(84, 0.5, 1.8, 0.7, 0.3),
};

/// 某种烟花的基准 spec（colors 取调色板 sparks 的下标）。
BurstSpec burstPreset(
  BurstKind kind, [
  List<int> colors = const <int>[0, 1, 2],
]) {
  final _BurstBase b = _burstPresets[kind]!;
  return BurstSpec(
    kind: kind,
    count: b.count,
    radius: b.radius,
    duration: b.duration,
    colors: colors,
    trail: b.trail,
    twinkle: b.twinkle,
  );
}

BurstSpec _burst(
  BurstKind kind,
  List<int> colors, {
  int? count,
  double? radius,
  double? duration,
}) => burstPreset(
  kind,
  colors,
).copyWith(count: count, radius: radius, duration: duration);

/// 被唱到的字放的小烟花。
BurstSpec _small(
  BurstKind kind,
  List<int> colors, {
  int count = 14,
  double radius = 0.05,
  double duration = 0.8,
  double? trail,
  double? twinkle,
}) => burstPreset(kind, colors).copyWith(
  count: count,
  radius: radius,
  duration: duration,
  trail: trail,
  twinkle: twinkle,
);

OrnamentSpec _orn(
  OrnamentKind kind,
  OrnamentPlacement placement,
  OrnamentLayer layer, {
  double density = 0.6,
  double scale = 1,
  OrnamentColor color = OrnamentColor.accent,
  double delay = 0,
}) => OrnamentSpec(
  kind: kind,
  placement: placement,
  layer: layer,
  density: density,
  scale: scale,
  color: color,
  delay: delay,
);

/// 文字区：离画面边缘至少 6%。
class HanabiRegions {
  static const HanabiRegion center = HanabiRegion(0.5, 0.5, 0.74, 0.34);
  static const HanabiRegion left = HanabiRegion(0.42, 0.56, 0.6, 0.34);
  static const HanabiRegion right = HanabiRegion(0.58, 0.46, 0.6, 0.34);
  static const HanabiRegion stagger = HanabiRegion(0.5, 0.5, 0.7, 0.46);
  static const HanabiRegion diagonal = HanabiRegion(0.5, 0.5, 0.74, 0.5);
  static const HanabiRegion scatter = HanabiRegion(0.5, 0.5, 0.78, 0.56);
  static const HanabiRegion vertical = HanabiRegion(0.5, 0.5, 0.34, 0.72);
  static const HanabiRegion verticalRight = HanabiRegion(0.62, 0.5, 0.3, 0.72);
  static const HanabiRegion verticalSplit = HanabiRegion(0.5, 0.5, 0.46, 0.72);
  static const HanabiRegion arc = HanabiRegion(0.5, 0.54, 0.74, 0.4);
  static const HanabiRegion giant = HanabiRegion(0.5, 0.5, 0.8, 0.52);
  static const HanabiRegion giantLeft = HanabiRegion(0.44, 0.52, 0.68, 0.5);
}

const Map<TextLayoutKind, HanabiRegion> _regionOfLayout =
    <TextLayoutKind, HanabiRegion>{
      TextLayoutKind.center: HanabiRegions.center,
      TextLayoutKind.left: HanabiRegions.left,
      TextLayoutKind.right: HanabiRegions.right,
      TextLayoutKind.stagger: HanabiRegions.stagger,
      TextLayoutKind.diagonal: HanabiRegions.diagonal,
      TextLayoutKind.scatter: HanabiRegions.scatter,
      TextLayoutKind.vertical: HanabiRegions.vertical,
      TextLayoutKind.verticalSplit: HanabiRegions.verticalSplit,
      TextLayoutKind.arc: HanabiRegions.arc,
    };

/// 一族的共同气质。
class _FamilyBase {
  const _FamilyBase({
    required this.heroSize,
    required this.emphasis,
    required this.stagger,
    required this.outline,
    required this.hardShadow,
    required this.burstAt,
    required this.sungBurst,
    required this.launch,
    required this.camera,
  });

  final double heroSize;
  final double emphasis;
  final double stagger;
  final bool outline;
  final bool hardShadow;
  final BurstAt burstAt;
  final BurstSpec? sungBurst;
  final bool launch;
  final HanabiCamera camera;
}

class _Recipe {
  const _Recipe(
    this.kind,
    this.label,
    this.mood,
    this.layout,
    this.block,
    this.enter,
    this.sing,
    this.exit,
    this.palette,
    this.burst,
    this.ornaments, {
    this.region,
    this.heroSize,
    this.emphasis,
    this.tilt,
    this.stagger,
    this.outline,
    this.hardShadow,
    this.burstAt,
    this.sungBurst,
    this.rise,
    this.push,
    this.roll,
    this.punch,
  });

  final String kind;
  final String label;
  final HanabiMood mood;
  final TextLayoutKind layout;
  final BlockStyle block;
  final EnterFx enter;
  final SingFx sing;
  final ExitFx exit;
  final PaletteRole palette;
  final BurstSpec? burst;
  final List<OrnamentSpec> ornaments;
  final HanabiRegion? region;
  final double? heroSize;
  final double? emphasis;
  final double? tilt;
  final double? stagger;
  final bool? outline;
  final bool? hardShadow;
  final BurstAt? burstAt;
  final BurstSpec? sungBurst;
  final double? rise;
  final double? push;
  final double? roll;
  final double? punch;
}

List<HanabiProfile> _family(
  String id,
  _FamilyBase base,
  List<_Recipe> recipes,
) => <HanabiProfile>[
  for (final _Recipe r in recipes)
    HanabiProfile(
      kind: r.kind,
      label: r.label,
      family: id,
      mood: r.mood,
      text: TextSpec(
        layout: r.layout,
        heroSize: r.heroSize ?? base.heroSize,
        emphasis: r.emphasis ?? base.emphasis,
        tilt: r.tilt ?? 0,
        block: r.block,
        enter: r.enter,
        sing: r.sing,
        exit: r.exit,
        stagger: r.stagger ?? base.stagger,
        outline: r.outline ?? base.outline,
        hardShadow: r.hardShadow ?? base.hardShadow,
      ),
      region: r.region ?? _regionOfLayout[r.layout]!,
      burst: r.burst,
      burstAt: r.burstAt ?? base.burstAt,
      sungBurst: r.sungBurst ?? base.sungBurst,
      ornaments: r.ornaments,
      launch: base.launch,
      palette: r.palette,
      camera: base.camera.merge(
        rise: r.rise,
        push: r.push,
        roll: r.roll,
        punch: r.punch,
      ),
    ),
];

// 简写。
const OrnamentPlacement _glyphs = OrnamentPlacement.glyphs;
const OrnamentPlacement _around = OrnamentPlacement.around;
const OrnamentPlacement _behind = OrnamentPlacement.behind;
const OrnamentPlacement _corners = OrnamentPlacement.corners;
const OrnamentPlacement _lineStart = OrnamentPlacement.lineStart;
const OrnamentPlacement _lineEnd = OrnamentPlacement.lineEnd;
const OrnamentPlacement _screen = OrnamentPlacement.screen;
const OrnamentLayer _back = OrnamentLayer.back;
const OrnamentLayer _front = OrnamentLayer.front;
const OrnamentColor _spark = OrnamentColor.spark;
const OrnamentColor _accent = OrnamentColor.accent;
const OrnamentColor _blockC = OrnamentColor.block;
const OrnamentColor _paper = OrnamentColor.paper;
const OrnamentColor _glowC = OrnamentColor.glow;

List<HanabiProfile> _buildProfiles() => <HanabiProfile>[
  // 打上：升空尾迹 + 从下往上升入，镜头上升最多。
  ..._family(
    'uchiage',
    const _FamilyBase(
      heroSize: 0.1,
      emphasis: 0.45,
      stagger: 0.045,
      outline: false,
      hardShadow: true,
      burstAt: BurstAt.above,
      sungBurst: null,
      launch: true,
      camera: HanabiCamera(rise: 0.72, push: 0.04, roll: 0.01, punch: 0.35),
    ),
    <_Recipe>[
      _Recipe(
        'uchiage-kiku',
        '打上·菊',
        HanabiMood.neutral,
        TextLayoutKind.center,
        BlockStyle.band,
        EnterFx.rise,
        SingFx.bounce,
        ExitFx.ascend,
        PaletteRole.kawaii,
        _burst(BurstKind.kiku, <int>[0, 1, 2]),
        <OrnamentSpec>[
          _orn(
            OrnamentKind.streaks,
            _screen,
            _back,
            density: 0.5,
            color: _spark,
            delay: -0.3,
          ),
          _orn(
            OrnamentKind.sparkle,
            _glyphs,
            _front,
            density: 0.5,
            color: _glowC,
          ),
          _orn(
            OrnamentKind.ring,
            _behind,
            _back,
            scale: 1.1,
            color: _spark,
            delay: 0.05,
          ),
        ],
      ),
      _Recipe(
        'uchiage-botan',
        '打上·牡丹',
        HanabiMood.loud,
        TextLayoutKind.stagger,
        BlockStyle.pill,
        EnterFx.rise,
        SingFx.jump,
        ExitFx.ascend,
        PaletteRole.festival,
        _burst(BurstKind.botan, <int>[0, 1, 2, 3], count: 96),
        <OrnamentSpec>[
          _orn(
            OrnamentKind.chevrons,
            _lineEnd,
            _back,
            density: 0.7,
            color: _blockC,
          ),
          _orn(
            OrnamentKind.confetti,
            _screen,
            _front,
            density: 0.55,
            color: _spark,
            delay: 0.1,
          ),
          _orn(
            OrnamentKind.dotsLine,
            _glyphs,
            _back,
            density: 0.6,
            color: _paper,
          ),
        ],
        sungBurst: _small(BurstKind.botan, <int>[0, 1, 2]),
        rise: 0.8,
        punch: 0.5,
      ),
      _Recipe(
        'uchiage-palm',
        '打上·椰',
        HanabiMood.neutral,
        TextLayoutKind.left,
        BlockStyle.slant,
        EnterFx.elastic,
        SingFx.swell,
        ExitFx.ascend,
        PaletteRole.ocean,
        _burst(BurstKind.palm, <int>[0, 1]),
        <OrnamentSpec>[
          _orn(
            OrnamentKind.streaks,
            _lineStart,
            _back,
            density: 0.45,
            color: _spark,
          ),
          _orn(
            OrnamentKind.underline,
            _glyphs,
            _back,
            color: _blockC,
            scale: 1.1,
          ),
          _orn(
            OrnamentKind.cross,
            _around,
            _front,
            density: 0.4,
            scale: 0.8,
            color: _paper,
          ),
        ],
        burstAt: BurstAt.sides,
        tilt: -0.05,
      ),
      _Recipe(
        'uchiage-crossette',
        '打上·分裂',
        HanabiMood.neutral,
        TextLayoutKind.arc,
        BlockStyle.none,
        EnterFx.wave,
        SingFx.flash,
        ExitFx.ascend,
        PaletteRole.night,
        _burst(BurstKind.crossette, <int>[0, 2, 3]),
        <OrnamentSpec>[
          _orn(
            OrnamentKind.dashCircle,
            _behind,
            _back,
            scale: 1.2,
            color: _glowC,
            delay: -0.1,
          ),
          _orn(
            OrnamentKind.sparkle,
            _glyphs,
            _front,
            density: 0.7,
            color: _spark,
          ),
          _orn(
            OrnamentKind.streaks,
            _screen,
            _back,
            density: 0.35,
            color: _paper,
            delay: -0.4,
          ),
        ],
        outline: true,
        hardShadow: false,
        heroSize: 0.095,
      ),
      _Recipe(
        'uchiage-double',
        '打上·锦',
        HanabiMood.neutral,
        TextLayoutKind.center,
        BlockStyle.double,
        EnterFx.drop,
        SingFx.bounce,
        ExitFx.scatter,
        PaletteRole.gold,
        _burst(BurstKind.willowRing, <int>[0, 1, 2]),
        <OrnamentSpec>[
          _orn(
            OrnamentKind.rays,
            _behind,
            _back,
            density: 0.5,
            scale: 1.2,
            color: _glowC,
            delay: 0.05,
          ),
          _orn(
            OrnamentKind.glints,
            _glyphs,
            _front,
            density: 0.6,
            color: _paper,
          ),
          _orn(
            OrnamentKind.chevrons,
            _lineStart,
            _back,
            density: 0.5,
            color: _accent,
          ),
        ],
        burstAt: BurstAt.behind,
        rise: 0.65,
      ),
    ],
  ),
  // 菊：居中大字、背后开菊，集中线与圆环。
  ..._family(
    'kiku',
    const _FamilyBase(
      heroSize: 0.13,
      emphasis: 0.35,
      stagger: 0.035,
      outline: true,
      hardShadow: false,
      burstAt: BurstAt.behind,
      sungBurst: null,
      launch: true,
      camera: HanabiCamera(rise: 0.55, push: 0.07, roll: 0, punch: 0.5),
    ),
    <_Recipe>[
      _Recipe(
        'kiku-center',
        '菊·正面',
        HanabiMood.loud,
        TextLayoutKind.center,
        BlockStyle.none,
        EnterFx.zoom,
        SingFx.glow,
        ExitFx.shrink,
        PaletteRole.night,
        _burst(BurstKind.kiku, <int>[0, 1, 2, 3], count: 120, radius: 0.36),
        <OrnamentSpec>[
          _orn(
            OrnamentKind.spokes,
            _behind,
            _back,
            density: 0.8,
            scale: 1.3,
            color: _paper,
            delay: 0.05,
          ),
          _orn(
            OrnamentKind.ring,
            _behind,
            _back,
            density: 0.7,
            scale: 1.4,
            color: _spark,
            delay: 0.1,
          ),
          _orn(
            OrnamentKind.glints,
            _glyphs,
            _front,
            density: 0.5,
            color: _glowC,
          ),
        ],
      ),
      _Recipe(
        'kiku-ring',
        '菊·輪',
        HanabiMood.loud,
        TextLayoutKind.center,
        BlockStyle.outline,
        EnterFx.burst,
        SingFx.flash,
        ExitFx.dissolve,
        PaletteRole.neon,
        _burst(BurstKind.ring, <int>[0, 1, 2], count: 72),
        <OrnamentSpec>[
          _orn(
            OrnamentKind.ring,
            _around,
            _back,
            density: 0.9,
            scale: 1.2,
            color: _accent,
          ),
          _orn(
            OrnamentKind.dashCircle,
            _behind,
            _back,
            scale: 1.5,
            color: _glowC,
            delay: -0.15,
          ),
          _orn(
            OrnamentKind.sparkle,
            _glyphs,
            _front,
            density: 0.6,
            color: _spark,
          ),
        ],
        punch: 0.65,
      ),
      _Recipe(
        'kiku-spokes',
        '菊·集中线',
        HanabiMood.neutral,
        TextLayoutKind.center,
        BlockStyle.circle,
        EnterFx.pop,
        SingFx.bounce,
        ExitFx.scatter,
        PaletteRole.festival,
        _burst(BurstKind.kiku, <int>[1, 2, 0]),
        <OrnamentSpec>[
          _orn(
            OrnamentKind.spokes,
            _around,
            _back,
            density: 0.9,
            scale: 1.1,
            color: _blockC,
          ),
          _orn(
            OrnamentKind.shards,
            _around,
            _front,
            density: 0.45,
            color: _spark,
            delay: 0.1,
          ),
          _orn(
            OrnamentKind.ring,
            _behind,
            _back,
            density: 0.5,
            color: _paper,
            delay: 0.15,
          ),
        ],
        heroSize: 0.11,
        outline: false,
        hardShadow: true,
      ),
      _Recipe(
        'kiku-halo',
        '菊·光冠',
        HanabiMood.neutral,
        TextLayoutKind.arc,
        BlockStyle.tile,
        EnterFx.spiral,
        SingFx.swell,
        ExitFx.ascend,
        PaletteRole.gold,
        _burst(BurstKind.kamuro, <int>[0, 1], radius: 0.32),
        <OrnamentSpec>[
          _orn(
            OrnamentKind.dashCircle,
            _behind,
            _back,
            scale: 1.3,
            color: _accent,
          ),
          _orn(
            OrnamentKind.orbit,
            _around,
            _front,
            density: 0.6,
            color: _glowC,
          ),
          _orn(
            OrnamentKind.glints,
            _glyphs,
            _front,
            density: 0.4,
            color: _paper,
          ),
        ],
        burstAt: BurstAt.above,
        heroSize: 0.1,
        outline: false,
        push: 0.05,
        roll: 0.012,
      ),
      _Recipe(
        'kiku-marker',
        '菊·荧光',
        HanabiMood.neutral,
        TextLayoutKind.right,
        BlockStyle.marker,
        EnterFx.wipe,
        SingFx.underline,
        ExitFx.slide,
        PaletteRole.ocean,
        _burst(BurstKind.kiku, <int>[0, 2]),
        <OrnamentSpec>[
          _orn(
            OrnamentKind.ring,
            _lineStart,
            _back,
            density: 0.5,
            color: _spark,
          ),
          _orn(
            OrnamentKind.spokes,
            _corners,
            _back,
            density: 0.5,
            scale: 0.8,
            color: _paper,
          ),
          _orn(
            OrnamentKind.dotsLine,
            _glyphs,
            _front,
            density: 0.6,
            color: _accent,
          ),
        ],
        burstAt: BurstAt.sky,
        heroSize: 0.1,
        outline: false,
        stagger: 0.05,
        push: 0.03,
        punch: 0.25,
      ),
    ],
  ),
  // 牡丹：饱满的大色块、弹出与砸下、圆润的色点。
  ..._family(
    'botan',
    const _FamilyBase(
      heroSize: 0.11,
      emphasis: 0.6,
      stagger: 0.05,
      outline: false,
      hardShadow: true,
      burstAt: BurstAt.behind,
      sungBurst: null,
      launch: false,
      camera: HanabiCamera(rise: 0.5, push: 0.05, roll: 0, punch: 0.6),
    ),
    <_Recipe>[
      _Recipe(
        'botan-band',
        '牡丹·色带',
        HanabiMood.loud,
        TextLayoutKind.center,
        BlockStyle.band,
        EnterFx.stamp,
        SingFx.jump,
        ExitFx.shrink,
        PaletteRole.festival,
        _burst(BurstKind.botan, <int>[0, 1, 2, 3], count: 110),
        <OrnamentSpec>[
          _orn(
            OrnamentKind.halftone,
            _behind,
            _back,
            density: 0.7,
            scale: 1.3,
            color: _blockC,
          ),
          _orn(
            OrnamentKind.confetti,
            _screen,
            _front,
            density: 0.6,
            color: _spark,
            delay: 0.05,
          ),
          _orn(
            OrnamentKind.squares,
            _around,
            _back,
            density: 0.5,
            color: _accent,
          ),
        ],
        heroSize: 0.12,
        punch: 0.8,
      ),
      _Recipe(
        'botan-tile',
        '牡丹·方块',
        HanabiMood.neutral,
        TextLayoutKind.stagger,
        BlockStyle.tile,
        EnterFx.pop,
        SingFx.color,
        ExitFx.scatter,
        PaletteRole.pastel,
        _burst(BurstKind.botan, <int>[1, 2, 3]),
        <OrnamentSpec>[
          _orn(
            OrnamentKind.squares,
            _corners,
            _back,
            density: 0.6,
            color: _blockC,
          ),
          _orn(
            OrnamentKind.confetti,
            _screen,
            _front,
            density: 0.4,
            color: _spark,
          ),
          _orn(
            OrnamentKind.cross,
            _around,
            _front,
            density: 0.5,
            scale: 0.8,
            color: _accent,
          ),
        ],
        sungBurst: _small(BurstKind.botan, <int>[0, 1, 2, 3], count: 10),
        punch: 0.4,
      ),
      _Recipe(
        'botan-double',
        '牡丹·心',
        HanabiMood.loud,
        TextLayoutKind.left,
        BlockStyle.double,
        EnterFx.stamp,
        SingFx.bounce,
        ExitFx.blink,
        PaletteRole.sakura,
        _burst(BurstKind.heart, <int>[0, 2]),
        <OrnamentSpec>[
          _orn(
            OrnamentKind.halftone,
            _behind,
            _back,
            density: 0.6,
            color: _accent,
          ),
          _orn(
            OrnamentKind.stamp,
            _lineEnd,
            _front,
            scale: 1.1,
            color: _accent,
            delay: 0.3,
          ),
          _orn(
            OrnamentKind.sparkle,
            _glyphs,
            _front,
            density: 0.5,
            color: _paper,
          ),
        ],
        burstAt: BurstAt.sides,
        tilt: -0.04,
      ),
      _Recipe(
        'botan-split',
        '牡丹·双色',
        HanabiMood.loud,
        TextLayoutKind.diagonal,
        BlockStyle.split,
        EnterFx.flip,
        SingFx.jump,
        ExitFx.slide,
        PaletteRole.neon,
        _burst(BurstKind.botan, <int>[0, 1]),
        <OrnamentSpec>[
          _orn(
            OrnamentKind.shards,
            _around,
            _front,
            density: 0.55,
            color: _spark,
          ),
          _orn(
            OrnamentKind.chevrons,
            _lineEnd,
            _back,
            density: 0.7,
            color: _blockC,
          ),
          _orn(
            OrnamentKind.zigzag,
            _around,
            _back,
            density: 0.6,
            color: _accent,
          ),
        ],
        burstAt: BurstAt.above,
        tilt: -0.12,
        roll: 0.02,
      ),
      _Recipe(
        'botan-circle',
        '牡丹·丸',
        HanabiMood.neutral,
        TextLayoutKind.scatter,
        BlockStyle.circle,
        EnterFx.pop,
        SingFx.bounce,
        ExitFx.shrink,
        PaletteRole.pastel,
        _burst(BurstKind.star, <int>[0, 1, 3]),
        <OrnamentSpec>[
          _orn(OrnamentKind.cross, _screen, _back, density: 0.5, color: _paper),
          _orn(
            OrnamentKind.confetti,
            _around,
            _front,
            density: 0.5,
            color: _blockC,
          ),
          _orn(
            OrnamentKind.orbit,
            _around,
            _back,
            density: 0.5,
            color: _accent,
          ),
        ],
        burstAt: BurstAt.sky,
        heroSize: 0.09,
        emphasis: 0.8,
        punch: 0.35,
      ),
    ],
  ),
  // 柳：竖排、慢，柳火与冠下垂，字落下退场。
  ..._family(
    'yanagi',
    const _FamilyBase(
      heroSize: 0.085,
      emphasis: 0.2,
      stagger: 0.09,
      outline: false,
      hardShadow: false,
      burstAt: BurstAt.above,
      sungBurst: null,
      launch: true,
      camera: HanabiCamera(rise: 0.35, push: 0.025, roll: 0.006, punch: 0),
    ),
    <_Recipe>[
      _Recipe(
        'yanagi-shidare',
        '柳·枝垂',
        HanabiMood.quiet,
        TextLayoutKind.vertical,
        BlockStyle.none,
        EnterFx.drop,
        SingFx.glow,
        ExitFx.fall,
        PaletteRole.night,
        _burst(BurstKind.yanagi, <int>[0, 1]),
        <OrnamentSpec>[
          _orn(
            OrnamentKind.petals,
            _screen,
            _front,
            density: 0.3,
            color: _glowC,
            delay: 0.4,
          ),
          _orn(
            OrnamentKind.dotsLine,
            _glyphs,
            _back,
            density: 0.5,
            scale: 0.8,
            color: _spark,
          ),
          _orn(
            OrnamentKind.glints,
            _glyphs,
            _front,
            density: 0.35,
            color: _paper,
          ),
        ],
      ),
      _Recipe(
        'yanagi-kamuro',
        '柳·金冠',
        HanabiMood.quiet,
        TextLayoutKind.verticalSplit,
        BlockStyle.outline,
        EnterFx.wipe,
        SingFx.glow,
        ExitFx.fall,
        PaletteRole.gold,
        _burst(BurstKind.kamuro, <int>[0, 1, 2], duration: 4),
        <OrnamentSpec>[
          _orn(
            OrnamentKind.brackets,
            _around,
            _back,
            scale: 1.05,
            color: _accent,
            delay: 0.1,
          ),
          _orn(
            OrnamentKind.glints,
            _glyphs,
            _front,
            density: 0.4,
            color: _glowC,
          ),
          _orn(OrnamentKind.wave, _behind, _back, density: 0.35, color: _spark),
        ],
      ),
      _Recipe(
        'yanagi-ame',
        '柳·雨',
        HanabiMood.quiet,
        TextLayoutKind.vertical,
        BlockStyle.marker,
        EnterFx.wave,
        SingFx.underline,
        ExitFx.fall,
        PaletteRole.ocean,
        _burst(BurstKind.willowRing, <int>[0, 2], count: 80),
        <OrnamentSpec>[
          _orn(OrnamentKind.wave, _screen, _back, density: 0.4, color: _accent),
          _orn(
            OrnamentKind.streaks,
            _screen,
            _back,
            density: 0.3,
            scale: 0.8,
            color: _paper,
          ),
          _orn(
            OrnamentKind.dotsLine,
            _lineEnd,
            _front,
            density: 0.5,
            color: _spark,
          ),
        ],
        region: HanabiRegions.verticalRight,
      ),
      _Recipe(
        'yanagi-kaze',
        '柳·风',
        HanabiMood.quiet,
        TextLayoutKind.right,
        BlockStyle.none,
        EnterFx.drop,
        SingFx.swell,
        ExitFx.fall,
        PaletteRole.sakura,
        _burst(BurstKind.yanagi, <int>[0, 1, 3]),
        <OrnamentSpec>[
          _orn(
            OrnamentKind.petals,
            _screen,
            _front,
            density: 0.5,
            color: _blockC,
          ),
          _orn(
            OrnamentKind.sparkle,
            _glyphs,
            _front,
            density: 0.35,
            color: _glowC,
          ),
          _orn(
            OrnamentKind.wave,
            _lineStart,
            _back,
            density: 0.4,
            color: _accent,
          ),
        ],
        burstAt: BurstAt.sky,
        heroSize: 0.08,
        stagger: 0.07,
      ),
      _Recipe(
        'yanagi-palm',
        '柳·椰影',
        HanabiMood.quiet,
        TextLayoutKind.verticalSplit,
        BlockStyle.pill,
        EnterFx.rise,
        SingFx.color,
        ExitFx.dissolve,
        PaletteRole.kawaii,
        _burst(BurstKind.palm, <int>[0, 2], duration: 2.8),
        <OrnamentSpec>[
          _orn(
            OrnamentKind.brackets,
            _around,
            _back,
            color: _paper,
            delay: 0.1,
          ),
          _orn(
            OrnamentKind.petals,
            _screen,
            _front,
            density: 0.25,
            color: _spark,
          ),
          _orn(
            OrnamentKind.dashCircle,
            _behind,
            _back,
            scale: 1.3,
            color: _glowC,
          ),
        ],
        burstAt: BurstAt.sides,
      ),
    ],
  ),
  // 千輪：每个被唱到的字各开一朵小花，散落与错落，快节奏。
  ..._family(
    'senrin',
    _FamilyBase(
      heroSize: 0.09,
      emphasis: 0.7,
      stagger: 0.03,
      outline: false,
      hardShadow: true,
      burstAt: BurstAt.behind,
      sungBurst: _small(
        BurstKind.senrin,
        <int>[0, 1, 2, 3],
        count: 16,
        radius: 0.06,
      ),
      launch: false,
      camera: const HanabiCamera(
        rise: 0.45,
        push: 0.04,
        roll: 0.012,
        punch: 0.4,
      ),
    ),
    <_Recipe>[
      _Recipe(
        'senrin-scatter',
        '千輪·散',
        HanabiMood.loud,
        TextLayoutKind.scatter,
        BlockStyle.pill,
        EnterFx.pop,
        SingFx.jump,
        ExitFx.scatter,
        PaletteRole.festival,
        _burst(BurstKind.senrin, <int>[0, 1, 2, 3]),
        <OrnamentSpec>[
          _orn(
            OrnamentKind.confetti,
            _screen,
            _front,
            density: 0.6,
            color: _spark,
          ),
          _orn(
            OrnamentKind.cross,
            _around,
            _back,
            density: 0.6,
            color: _accent,
          ),
          _orn(
            OrnamentKind.sparkle,
            _glyphs,
            _front,
            density: 0.5,
            color: _paper,
          ),
        ],
      ),
      _Recipe(
        'senrin-stagger',
        '千輪·阶',
        HanabiMood.neutral,
        TextLayoutKind.stagger,
        BlockStyle.tile,
        EnterFx.burst,
        SingFx.bounce,
        ExitFx.shrink,
        PaletteRole.neon,
        _burst(BurstKind.senrin, <int>[1, 2, 3]),
        <OrnamentSpec>[
          _orn(
            OrnamentKind.squares,
            _around,
            _back,
            density: 0.5,
            color: _blockC,
          ),
          _orn(
            OrnamentKind.shards,
            _around,
            _front,
            density: 0.45,
            color: _spark,
          ),
          _orn(
            OrnamentKind.sparkle,
            _glyphs,
            _front,
            density: 0.4,
            color: _glowC,
          ),
        ],
      ),
      _Recipe(
        'senrin-strobe',
        '千輪·点滅',
        HanabiMood.neutral,
        TextLayoutKind.scatter,
        BlockStyle.circle,
        EnterFx.spin,
        SingFx.flash,
        ExitFx.blink,
        PaletteRole.pastel,
        _burst(BurstKind.strobe, <int>[0, 1, 2, 3]),
        <OrnamentSpec>[
          _orn(OrnamentKind.cross, _screen, _back, density: 0.5, color: _paper),
          _orn(
            OrnamentKind.orbit,
            _around,
            _front,
            density: 0.5,
            color: _spark,
          ),
          _orn(
            OrnamentKind.dotsLine,
            _glyphs,
            _back,
            density: 0.5,
            color: _accent,
          ),
        ],
        burstAt: BurstAt.sky,
        sungBurst: _small(BurstKind.strobe, <int>[0, 1, 2, 3], twinkle: 1),
      ),
      _Recipe(
        'senrin-hachi',
        '千輪·蜂',
        HanabiMood.loud,
        TextLayoutKind.diagonal,
        BlockStyle.stair,
        EnterFx.spin,
        SingFx.shake,
        ExitFx.scatter,
        PaletteRole.festival,
        _burst(BurstKind.hachi, <int>[0, 1, 2]),
        <OrnamentSpec>[
          _orn(
            OrnamentKind.zigzag,
            _around,
            _back,
            density: 0.7,
            color: _blockC,
          ),
          _orn(
            OrnamentKind.confetti,
            _screen,
            _front,
            density: 0.5,
            color: _spark,
          ),
          _orn(
            OrnamentKind.chevrons,
            _lineEnd,
            _front,
            density: 0.5,
            color: _paper,
          ),
        ],
        sungBurst: _small(BurstKind.hachi, <int>[0, 1, 2], count: 12),
        tilt: -0.1,
        roll: 0.02,
        punch: 0.55,
      ),
      _Recipe(
        'senrin-heart',
        '千輪·心',
        HanabiMood.neutral,
        TextLayoutKind.arc,
        BlockStyle.pill,
        EnterFx.pop,
        SingFx.bounce,
        ExitFx.shrink,
        PaletteRole.sakura,
        _burst(BurstKind.heart, <int>[0, 1]),
        <OrnamentSpec>[
          _orn(
            OrnamentKind.petals,
            _screen,
            _front,
            density: 0.45,
            color: _blockC,
          ),
          _orn(
            OrnamentKind.confetti,
            _around,
            _front,
            density: 0.35,
            color: _spark,
          ),
          _orn(
            OrnamentKind.sparkle,
            _glyphs,
            _front,
            density: 0.4,
            color: _paper,
          ),
        ],
        burstAt: BurstAt.above,
        sungBurst: _small(BurstKind.heart, <int>[0, 2], count: 12),
      ),
    ],
  ),
  // 星屑：四角星、光点、点线，发光强调、碎成星屑退场。
  ..._family(
    'hoshikuzu',
    _FamilyBase(
      heroSize: 0.085,
      emphasis: 0.3,
      stagger: 0.07,
      outline: false,
      hardShadow: false,
      burstAt: BurstAt.sky,
      sungBurst: _small(
        BurstKind.star,
        <int>[0, 1, 2],
        count: 10,
        radius: 0.04,
        duration: 1,
      ),
      launch: false,
      camera: const HanabiCamera(rise: 0.4, push: 0.03, roll: 0.008, punch: 0),
    ),
    <_Recipe>[
      _Recipe(
        'hoshikuzu-star',
        '星屑·星',
        HanabiMood.quiet,
        TextLayoutKind.center,
        BlockStyle.none,
        EnterFx.spiral,
        SingFx.glow,
        ExitFx.dissolve,
        PaletteRole.night,
        _burst(BurstKind.star, <int>[0, 2]),
        <OrnamentSpec>[
          _orn(
            OrnamentKind.sparkle,
            _glyphs,
            _front,
            density: 0.7,
            color: _glowC,
          ),
          _orn(
            OrnamentKind.glints,
            _glyphs,
            _front,
            density: 0.5,
            color: _paper,
          ),
          _orn(
            OrnamentKind.orbit,
            _around,
            _back,
            density: 0.4,
            scale: 1.2,
            color: _spark,
          ),
        ],
        burstAt: BurstAt.above,
      ),
      _Recipe(
        'hoshikuzu-orbit',
        '星屑·轨道',
        HanabiMood.quiet,
        TextLayoutKind.arc,
        BlockStyle.outline,
        EnterFx.zoom,
        SingFx.glow,
        ExitFx.dissolve,
        PaletteRole.ocean,
        _burst(BurstKind.strobe, <int>[0, 1, 2], count: 56),
        <OrnamentSpec>[
          _orn(
            OrnamentKind.orbit,
            _around,
            _front,
            density: 0.7,
            color: _glowC,
          ),
          _orn(
            OrnamentKind.dashCircle,
            _behind,
            _back,
            scale: 1.4,
            color: _accent,
          ),
          _orn(
            OrnamentKind.sparkle,
            _around,
            _front,
            density: 0.4,
            color: _paper,
          ),
        ],
      ),
      _Recipe(
        'hoshikuzu-dust',
        '星屑·尘',
        HanabiMood.quiet,
        TextLayoutKind.vertical,
        BlockStyle.circle,
        EnterFx.wave,
        SingFx.glow,
        ExitFx.dissolve,
        PaletteRole.pastel,
        _burst(BurstKind.ring, <int>[0, 1], count: 48, radius: 0.2),
        <OrnamentSpec>[
          _orn(
            OrnamentKind.dotsLine,
            _glyphs,
            _back,
            density: 0.6,
            color: _spark,
          ),
          _orn(
            OrnamentKind.sparkle,
            _screen,
            _front,
            density: 0.45,
            color: _glowC,
          ),
          _orn(
            OrnamentKind.petals,
            _screen,
            _front,
            density: 0.2,
            scale: 0.7,
            color: _paper,
          ),
        ],
        burstAt: BurstAt.behind,
      ),
      _Recipe(
        'hoshikuzu-line',
        '星屑·点线',
        HanabiMood.quiet,
        TextLayoutKind.left,
        BlockStyle.pill,
        EnterFx.zoom,
        SingFx.none,
        ExitFx.dissolve,
        PaletteRole.neon,
        _burst(BurstKind.crossette, <int>[0, 1]),
        <OrnamentSpec>[
          _orn(
            OrnamentKind.dotsLine,
            _lineEnd,
            _back,
            density: 0.7,
            color: _accent,
          ),
          _orn(
            OrnamentKind.glints,
            _glyphs,
            _front,
            density: 0.5,
            color: _glowC,
          ),
          _orn(
            OrnamentKind.cross,
            _corners,
            _back,
            density: 0.4,
            color: _paper,
          ),
        ],
      ),
      _Recipe(
        'hoshikuzu-veil',
        '星屑·纱',
        HanabiMood.quiet,
        TextLayoutKind.stagger,
        BlockStyle.none,
        EnterFx.spiral,
        SingFx.color,
        ExitFx.ascend,
        PaletteRole.sakura,
        _burst(BurstKind.kamuro, <int>[0, 1, 3], count: 90),
        <OrnamentSpec>[
          _orn(
            OrnamentKind.sparkle,
            _glyphs,
            _front,
            density: 0.6,
            color: _glowC,
          ),
          _orn(OrnamentKind.wave, _behind, _back, density: 0.4, color: _accent),
          _orn(
            OrnamentKind.orbit,
            _around,
            _back,
            density: 0.35,
            color: _spark,
          ),
        ],
      ),
    ],
  ),
  // 帯：色带排字，斜块、票据、荧光笔、阶梯，擦出、打字、滑动。
  ..._family(
    'obi',
    const _FamilyBase(
      heroSize: 0.09,
      emphasis: 0.4,
      stagger: 0.04,
      outline: false,
      hardShadow: false,
      burstAt: BurstAt.sides,
      sungBurst: null,
      launch: false,
      camera: HanabiCamera(rise: 0.5, push: 0.02, roll: 0, punch: 0.2),
    ),
    <_Recipe>[
      _Recipe(
        'obi-band',
        '帯·横带',
        HanabiMood.neutral,
        TextLayoutKind.left,
        BlockStyle.band,
        EnterFx.wipe,
        SingFx.underline,
        ExitFx.slide,
        PaletteRole.festival,
        _burst(BurstKind.ring, <int>[0, 1]),
        <OrnamentSpec>[
          _orn(
            OrnamentKind.zigzag,
            _lineEnd,
            _back,
            density: 0.6,
            color: _blockC,
          ),
          _orn(
            OrnamentKind.chevrons,
            _lineStart,
            _back,
            density: 0.5,
            color: _accent,
          ),
          _orn(OrnamentKind.underline, _glyphs, _front, color: _paper),
        ],
      ),
      _Recipe(
        'obi-ticket',
        '帯·票据',
        HanabiMood.neutral,
        TextLayoutKind.center,
        BlockStyle.ticket,
        EnterFx.flip,
        SingFx.color,
        ExitFx.slide,
        PaletteRole.pastel,
        _burst(BurstKind.botan, <int>[0, 2], count: 64),
        <OrnamentSpec>[
          _orn(OrnamentKind.brackets, _around, _back, color: _accent),
          _orn(
            OrnamentKind.dotsLine,
            _lineEnd,
            _back,
            density: 0.5,
            color: _paper,
          ),
          _orn(
            OrnamentKind.stamp,
            _lineStart,
            _front,
            scale: 0.9,
            color: _accent,
            delay: 0.35,
          ),
        ],
        burstAt: BurstAt.above,
      ),
      _Recipe(
        'obi-slant',
        '帯·斜块',
        HanabiMood.loud,
        TextLayoutKind.diagonal,
        BlockStyle.slant,
        EnterFx.wipe,
        SingFx.underline,
        ExitFx.slide,
        PaletteRole.neon,
        _burst(BurstKind.palm, <int>[0, 1, 2]),
        <OrnamentSpec>[
          _orn(
            OrnamentKind.chevrons,
            _lineEnd,
            _front,
            density: 0.7,
            color: _spark,
          ),
          _orn(
            OrnamentKind.streaks,
            _screen,
            _back,
            density: 0.5,
            color: _paper,
          ),
          _orn(
            OrnamentKind.zigzag,
            _around,
            _back,
            density: 0.5,
            color: _blockC,
          ),
        ],
        tilt: -0.14,
        hardShadow: true,
        punch: 0.45,
      ),
      _Recipe(
        'obi-marker',
        '帯·荧光笔',
        HanabiMood.neutral,
        TextLayoutKind.stagger,
        BlockStyle.marker,
        EnterFx.type,
        SingFx.underline,
        ExitFx.blink,
        PaletteRole.ocean,
        _burst(BurstKind.star, <int>[0, 1]),
        <OrnamentSpec>[
          _orn(
            OrnamentKind.underline,
            _glyphs,
            _back,
            scale: 1.2,
            color: _accent,
          ),
          _orn(
            OrnamentKind.squares,
            _corners,
            _back,
            density: 0.5,
            color: _blockC,
          ),
          _orn(
            OrnamentKind.brackets,
            _around,
            _front,
            scale: 1.1,
            color: _paper,
          ),
        ],
        burstAt: BurstAt.sky,
      ),
      _Recipe(
        'obi-stair',
        '帯·阶梯',
        HanabiMood.neutral,
        TextLayoutKind.right,
        BlockStyle.stair,
        EnterFx.stretch,
        SingFx.jump,
        ExitFx.slide,
        PaletteRole.gold,
        _burst(BurstKind.crossette, <int>[0, 1, 3]),
        <OrnamentSpec>[
          _orn(
            OrnamentKind.squares,
            _around,
            _back,
            density: 0.55,
            color: _accent,
          ),
          _orn(
            OrnamentKind.halftone,
            _behind,
            _back,
            density: 0.5,
            color: _blockC,
          ),
          _orn(
            OrnamentKind.chevrons,
            _lineStart,
            _front,
            density: 0.5,
            color: _paper,
          ),
        ],
        hardShadow: true,
      ),
    ],
  ),
  // 閃光：点滅、故障、乱码、频闪、速度线，硬切。
  ..._family(
    'senko',
    const _FamilyBase(
      heroSize: 0.1,
      emphasis: 0.5,
      stagger: 0.025,
      outline: false,
      hardShadow: true,
      burstAt: BurstAt.behind,
      sungBurst: null,
      launch: false,
      camera: HanabiCamera(rise: 0.6, push: 0.06, roll: 0.015, punch: 0.7),
    ),
    <_Recipe>[
      _Recipe(
        'senko-glitch',
        '閃光·故障',
        HanabiMood.loud,
        TextLayoutKind.center,
        BlockStyle.split,
        EnterFx.glitch,
        SingFx.shake,
        ExitFx.blink,
        PaletteRole.neon,
        _burst(BurstKind.strobe, <int>[0, 1, 2, 3]),
        <OrnamentSpec>[
          _orn(
            OrnamentKind.streaks,
            _screen,
            _back,
            density: 0.7,
            color: _spark,
          ),
          _orn(
            OrnamentKind.shards,
            _around,
            _front,
            density: 0.5,
            color: _blockC,
          ),
          _orn(
            OrnamentKind.squares,
            _around,
            _back,
            density: 0.5,
            color: _paper,
          ),
        ],
      ),
      _Recipe(
        'senko-scramble',
        '閃光·乱码',
        HanabiMood.neutral,
        TextLayoutKind.left,
        BlockStyle.outline,
        EnterFx.scramble,
        SingFx.flash,
        ExitFx.blink,
        PaletteRole.mono,
        _burst(BurstKind.hachi, <int>[0, 1]),
        <OrnamentSpec>[
          _orn(OrnamentKind.brackets, _around, _back, color: _paper),
          _orn(
            OrnamentKind.cross,
            _corners,
            _front,
            density: 0.5,
            color: _accent,
          ),
          _orn(
            OrnamentKind.streaks,
            _lineEnd,
            _back,
            density: 0.5,
            color: _glowC,
          ),
        ],
        burstAt: BurstAt.sides,
        outline: true,
        hardShadow: false,
        punch: 0.4,
      ),
      _Recipe(
        'senko-strobe',
        '閃光·频闪',
        HanabiMood.loud,
        TextLayoutKind.scatter,
        BlockStyle.tile,
        EnterFx.glitch,
        SingFx.flash,
        ExitFx.scatter,
        PaletteRole.kawaii,
        _burst(BurstKind.mine, <int>[0, 1, 2]),
        <OrnamentSpec>[
          _orn(
            OrnamentKind.streaks,
            _screen,
            _back,
            density: 0.8,
            color: _paper,
          ),
          _orn(
            OrnamentKind.zigzag,
            _around,
            _front,
            density: 0.5,
            color: _accent,
          ),
          _orn(
            OrnamentKind.glints,
            _glyphs,
            _front,
            density: 0.5,
            color: _glowC,
          ),
        ],
        burstAt: BurstAt.sky,
        sungBurst: _small(BurstKind.strobe, <int>[0, 1], count: 10, twinkle: 1),
      ),
      _Recipe(
        'senko-stretch',
        '閃光·拉伸',
        HanabiMood.loud,
        TextLayoutKind.center,
        BlockStyle.slant,
        EnterFx.stretch,
        SingFx.shake,
        ExitFx.shrink,
        PaletteRole.neon,
        _burst(BurstKind.crossette, <int>[0, 2, 3]),
        <OrnamentSpec>[
          _orn(
            OrnamentKind.spokes,
            _around,
            _back,
            density: 0.8,
            color: _paper,
          ),
          _orn(
            OrnamentKind.streaks,
            _screen,
            _front,
            density: 0.5,
            color: _spark,
          ),
          _orn(
            OrnamentKind.shards,
            _around,
            _back,
            density: 0.4,
            color: _blockC,
          ),
        ],
        tilt: -0.06,
      ),
      _Recipe(
        'senko-type',
        '閃光·打字',
        HanabiMood.neutral,
        TextLayoutKind.right,
        BlockStyle.ticket,
        EnterFx.scramble,
        SingFx.none,
        ExitFx.blink,
        PaletteRole.mono,
        _burst(BurstKind.ring, <int>[0, 1], count: 48),
        <OrnamentSpec>[
          _orn(
            OrnamentKind.dotsLine,
            _lineStart,
            _back,
            density: 0.6,
            color: _paper,
          ),
          _orn(
            OrnamentKind.brackets,
            _around,
            _front,
            scale: 1.08,
            color: _accent,
          ),
          _orn(
            OrnamentKind.cross,
            _screen,
            _back,
            density: 0.35,
            color: _glowC,
          ),
        ],
        burstAt: BurstAt.above,
        punch: 0.3,
        roll: 0,
      ),
    ],
  ),
  // 線香：小而密的火花贴着字噼啪，温柔，暗色调。
  ..._family(
    'senkohanabi',
    _FamilyBase(
      heroSize: 0.08,
      emphasis: 0.2,
      stagger: 0.08,
      outline: false,
      hardShadow: false,
      burstAt: BurstAt.behind,
      sungBurst: _small(
        BurstKind.hachi,
        <int>[0, 1],
        count: 12,
        radius: 0.035,
        duration: 0.6,
        trail: 0.4,
        twinkle: 0.8,
      ),
      launch: false,
      camera: const HanabiCamera(rise: 0.3, push: 0.02, roll: 0.004, punch: 0),
    ),
    <_Recipe>[
      _Recipe(
        'senkohanabi-hachi',
        '線香·火花',
        HanabiMood.quiet,
        TextLayoutKind.vertical,
        BlockStyle.none,
        EnterFx.type,
        SingFx.glow,
        ExitFx.fall,
        PaletteRole.gold,
        _burst(BurstKind.hachi, <int>[0, 1], count: 36, radius: 0.14),
        <OrnamentSpec>[
          _orn(
            OrnamentKind.glints,
            _glyphs,
            _front,
            density: 0.6,
            color: _spark,
          ),
          _orn(
            OrnamentKind.sparkle,
            _glyphs,
            _front,
            density: 0.35,
            scale: 0.7,
            color: _glowC,
          ),
          _orn(
            OrnamentKind.dotsLine,
            _glyphs,
            _back,
            density: 0.4,
            scale: 0.7,
            color: _accent,
          ),
        ],
        region: HanabiRegions.verticalRight,
      ),
      _Recipe(
        'senkohanabi-tama',
        '線香·火玉',
        HanabiMood.quiet,
        TextLayoutKind.center,
        BlockStyle.none,
        EnterFx.split,
        SingFx.glow,
        ExitFx.dissolve,
        PaletteRole.night,
        _burst(
          BurstKind.botan,
          <int>[0, 1],
          count: 40,
          radius: 0.12,
          duration: 1.2,
        ),
        <OrnamentSpec>[
          _orn(
            OrnamentKind.glints,
            _glyphs,
            _front,
            density: 0.5,
            color: _spark,
          ),
          _orn(
            OrnamentKind.sparkle,
            _around,
            _front,
            density: 0.3,
            scale: 0.7,
            color: _glowC,
          ),
        ],
        burstAt: BurstAt.above,
        heroSize: 0.085,
      ),
      _Recipe(
        'senkohanabi-matsuba',
        '線香·松葉',
        HanabiMood.quiet,
        TextLayoutKind.left,
        BlockStyle.circle,
        EnterFx.elastic,
        SingFx.swell,
        ExitFx.dissolve,
        PaletteRole.gold,
        _burst(BurstKind.crossette, <int>[0, 1], count: 28, radius: 0.15),
        <OrnamentSpec>[
          _orn(
            OrnamentKind.sparkle,
            _glyphs,
            _front,
            density: 0.45,
            color: _spark,
          ),
          _orn(
            OrnamentKind.cross,
            _around,
            _back,
            density: 0.35,
            scale: 0.7,
            color: _glowC,
          ),
        ],
        burstAt: BurstAt.sides,
      ),
      _Recipe(
        'senkohanabi-chiri',
        '線香·散菊',
        HanabiMood.quiet,
        TextLayoutKind.arc,
        BlockStyle.marker,
        EnterFx.flip,
        SingFx.underline,
        ExitFx.fall,
        PaletteRole.sakura,
        _burst(BurstKind.yanagi, <int>[0, 1], count: 40, radius: 0.18),
        <OrnamentSpec>[
          _orn(
            OrnamentKind.petals,
            _screen,
            _front,
            density: 0.35,
            color: _blockC,
          ),
          _orn(
            OrnamentKind.glints,
            _glyphs,
            _front,
            density: 0.4,
            color: _paper,
          ),
        ],
        burstAt: BurstAt.above,
      ),
      _Recipe(
        'senkohanabi-tsubomi',
        '線香·蕾',
        HanabiMood.quiet,
        TextLayoutKind.verticalSplit,
        BlockStyle.none,
        EnterFx.split,
        SingFx.glow,
        ExitFx.fall,
        PaletteRole.kawaii,
        _burst(BurstKind.strobe, <int>[0, 1], count: 30, radius: 0.14),
        <OrnamentSpec>[
          _orn(
            OrnamentKind.dotsLine,
            _glyphs,
            _back,
            density: 0.5,
            color: _spark,
          ),
          _orn(
            OrnamentKind.glints,
            _glyphs,
            _front,
            density: 0.5,
            color: _glowC,
          ),
          _orn(
            OrnamentKind.dashCircle,
            _behind,
            _back,
            scale: 0.9,
            density: 0.4,
            color: _paper,
          ),
        ],
      ),
    ],
  ),
  // 尺玉：一两个字的超大显示，巨大的冠与双层烟花、旭日放射。
  ..._family(
    'shakudama',
    const _FamilyBase(
      heroSize: 0.19,
      emphasis: 0.25,
      stagger: 0.06,
      outline: true,
      hardShadow: true,
      burstAt: BurstAt.behind,
      sungBurst: null,
      launch: true,
      camera: HanabiCamera(rise: 0.85, push: 0.09, roll: 0, punch: 0.9),
    ),
    <_Recipe>[
      _Recipe(
        'shakudama-kamuro',
        '尺玉·金冠',
        HanabiMood.loud,
        TextLayoutKind.center,
        BlockStyle.none,
        EnterFx.stamp,
        SingFx.none,
        ExitFx.shrink,
        PaletteRole.gold,
        _burst(
          BurstKind.kamuro,
          <int>[0, 1, 2],
          count: 160,
          radius: 0.48,
          duration: 4.2,
        ),
        <OrnamentSpec>[
          _orn(
            OrnamentKind.rays,
            _behind,
            _back,
            density: 0.8,
            scale: 1.5,
            color: _glowC,
          ),
          _orn(
            OrnamentKind.ring,
            _behind,
            _back,
            density: 0.6,
            scale: 1.6,
            color: _accent,
            delay: 0.1,
          ),
          _orn(
            OrnamentKind.spokes,
            _around,
            _front,
            density: 0.5,
            scale: 1.3,
            color: _paper,
          ),
        ],
        region: HanabiRegions.giant,
      ),
      _Recipe(
        'shakudama-nishiki',
        '尺玉·锦',
        HanabiMood.loud,
        TextLayoutKind.center,
        BlockStyle.double,
        EnterFx.zoom,
        SingFx.swell,
        ExitFx.scatter,
        PaletteRole.festival,
        _burst(
          BurstKind.willowRing,
          <int>[0, 1, 2, 3],
          count: 150,
          radius: 0.46,
        ),
        <OrnamentSpec>[
          _orn(
            OrnamentKind.rays,
            _behind,
            _back,
            density: 0.6,
            scale: 1.4,
            color: _blockC,
          ),
          _orn(
            OrnamentKind.stamp,
            _lineEnd,
            _front,
            scale: 1.2,
            color: _accent,
            delay: 0.4,
          ),
          _orn(
            OrnamentKind.ring,
            _around,
            _back,
            density: 0.7,
            scale: 1.3,
            color: _spark,
          ),
        ],
        region: HanabiRegions.giant,
        heroSize: 0.17,
      ),
      _Recipe(
        'shakudama-asahi',
        '尺玉·旭日',
        HanabiMood.loud,
        TextLayoutKind.center,
        BlockStyle.circle,
        EnterFx.burst,
        SingFx.flash,
        ExitFx.shrink,
        PaletteRole.festival,
        _burst(BurstKind.kamuro, <int>[1, 0], count: 140, radius: 0.44),
        <OrnamentSpec>[
          _orn(
            OrnamentKind.rays,
            _behind,
            _back,
            density: 0.9,
            scale: 1.6,
            color: _blockC,
          ),
          _orn(
            OrnamentKind.spokes,
            _behind,
            _back,
            density: 0.6,
            scale: 1.4,
            color: _paper,
          ),
          _orn(
            OrnamentKind.confetti,
            _screen,
            _front,
            density: 0.5,
            color: _spark,
            delay: 0.2,
          ),
        ],
        region: HanabiRegions.giant,
      ),
      _Recipe(
        'shakudama-heart',
        '尺玉·心',
        HanabiMood.loud,
        TextLayoutKind.center,
        BlockStyle.tile,
        EnterFx.stretch,
        SingFx.jump,
        ExitFx.scatter,
        PaletteRole.sakura,
        _burst(BurstKind.heart, <int>[0, 1, 3], count: 110, radius: 0.36),
        <OrnamentSpec>[
          _orn(
            OrnamentKind.stamp,
            _lineStart,
            _front,
            scale: 1.3,
            color: _accent,
            delay: 0.3,
          ),
          _orn(
            OrnamentKind.rays,
            _behind,
            _back,
            density: 0.5,
            scale: 1.3,
            color: _glowC,
          ),
          _orn(
            OrnamentKind.confetti,
            _screen,
            _front,
            density: 0.55,
            color: _blockC,
          ),
        ],
        region: HanabiRegions.giant,
        heroSize: 0.17,
      ),
      _Recipe(
        'shakudama-mine',
        '尺玉·速射',
        HanabiMood.loud,
        TextLayoutKind.left,
        BlockStyle.split,
        EnterFx.stamp,
        SingFx.shake,
        ExitFx.scatter,
        PaletteRole.neon,
        _burst(BurstKind.mine, <int>[0, 1, 2, 3], count: 120),
        <OrnamentSpec>[
          _orn(
            OrnamentKind.streaks,
            _screen,
            _back,
            density: 0.8,
            color: _spark,
          ),
          _orn(
            OrnamentKind.shards,
            _around,
            _front,
            density: 0.6,
            color: _blockC,
          ),
          _orn(
            OrnamentKind.rays,
            _behind,
            _back,
            density: 0.5,
            scale: 1.3,
            color: _accent,
          ),
        ],
        burstAt: BurstAt.sky,
        region: HanabiRegions.giantLeft,
        heroSize: 0.16,
        tilt: -0.05,
      ),
    ],
  ),
];

/// 全部 50 个预设。
final List<HanabiProfile> hanabiProfiles = _buildProfiles();

final Map<String, HanabiProfile> _byKind = <String, HanabiProfile>{
  for (final HanabiProfile p in hanabiProfiles) p.kind: p,
};

final List<String> hanabiKinds = <String>[
  for (final HanabiProfile p in hanabiProfiles) p.kind,
];

/// 未知的 kind 退回「打上·菊」。
HanabiProfile hanabiProfileOf(String kind) =>
    _byKind[kind] ?? hanabiProfiles.first;
