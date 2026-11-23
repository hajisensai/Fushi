/// 花火的场景（移植 folia `hanabi/scene.ts`、`credits.ts`、`hanabiScreenBloom.ts`）。
///
/// 节目单按段落建「装配」：每个镜头一套文字、烟花事件（主烟花、被唱到的字各一朵小花、碎成火花的退场、间奏连发）、
/// 装饰件；镜头挂在一条向上走的世界里，世界绕画面中心慢慢转，段落之间套转场帧。装配只在段落快出场时建，离场就放掉。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_ambient.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_collage.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_collage_decor.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_collage_plan.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_catalog.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_color.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_fireworks.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_math.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_ornaments.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_program.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_text.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_text_layout.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_beat_fx.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_timeline.dart';

enum HanabiQuality { full, balanced, low }

/// 调节项（每帧传入；影响装配的那部分进 [rigKey]）。
@immutable
class HanabiSettings {
  const HanabiSettings({
    this.colorMode = HanabiColorMode.mixed,
    this.sparkAmount = 1,
    this.ornamentAmount = 1,
    this.textMotion = 1,
    this.blockOpacity = 1,
    this.riseSpeed = 1,
    this.spin = 1,
    this.ambient = 1,
    this.glow = 1,
    this.bloom = 0.8,
    this.chorusBloom = 1.3,
    this.launches = true,
    this.overlayFrame = true,
    this.textOnly = false,
    this.sky = 0.85,
    this.collage = 1,
    this.quality = HanabiQuality.full,
  });

  final HanabiColorMode colorMode;
  final double sparkAmount;
  final double ornamentAmount;
  final double textMotion;
  final double blockOpacity;
  final double riseSpeed;
  final double spin;
  final double ambient;
  final double glow;
  final double bloom;
  final double chorusBloom;
  final bool launches;
  final bool overlayFrame;
  final bool textOnly;
  final double sky;
  final double collage;
  final HanabiQuality quality;

  Object get rigKey => Object.hash(
    colorMode,
    sparkAmount,
    ornamentAmount,
    textMotion,
    blockOpacity,
    riseSpeed,
    spin,
    launches,
    textOnly,
    sky >= 0.5,
    quality,
  );

  @override
  bool operator ==(Object other) =>
      other is HanabiSettings &&
      other.colorMode == colorMode &&
      other.sparkAmount == sparkAmount &&
      other.ornamentAmount == ornamentAmount &&
      other.textMotion == textMotion &&
      other.blockOpacity == blockOpacity &&
      other.riseSpeed == riseSpeed &&
      other.spin == spin &&
      other.ambient == ambient &&
      other.glow == glow &&
      other.bloom == bloom &&
      other.chorusBloom == chorusBloom &&
      other.launches == launches &&
      other.overlayFrame == overlayFrame &&
      other.textOnly == textOnly &&
      other.sky == sky &&
      other.collage == collage &&
      other.quality == quality;

  @override
  int get hashCode => Object.hash(
    rigKey,
    ambient,
    glow,
    bloom,
    chorusBloom,
    overlayFrame,
    collage,
  );
}

/// 一帧的输入。
class HanabiFrame {
  const HanabiFrame({
    required this.time,
    required this.motion,
    required this.theme,
    required this.settings,
    required this.fontScale,
    required this.baseStyle,
    this.intensityMotion = 1,
    this.keywordColor,
    this.keywordKey,
    this.beatEvents = const <HanabiBeatEvent>[],
    this.beatBursts = 0,
    this.pulseScale = 1,
    this.pulseRotation = 0,
  });

  /// 歌词时间（秒）。
  final double time;

  /// false：减弱动态效果，只留静的夜空与文字。
  final bool motion;
  final HanabiTheme theme;
  final HanabiSettings settings;
  final double fontScale;
  final TextStyle baseStyle;

  /// 动画强度对镜头运动的倍数（folia `MOTION`：平静 0.6 / 普通 1 / 激烈 1.4）。
  final double intensityMotion;

  /// 关键字色（主题 wordColors，folia `keywordColorOf`）：命中的字用这个颜色；null = 没有关键字。
  final int? Function(String text)? keywordColor;

  /// [keywordColor] 的内容标识（变了就重建装配）。
  final Object? keywordKey;

  /// 「随拍开花」的节拍表与强度（0 = 关）。
  final List<HanabiBeatEvent> beatEvents;
  final double beatBursts;

  /// 「随拍推镜」这一帧的整层缩放与旋转（弧度）。
  final double pulseScale;
  final double pulseRotation;
}

const double _prepareAhead = 1.5;
const int _maxSungBursts = 28;
const int _maxDissolveBursts = 24;
const List<BurstKind> _bridgeKinds = <BurstKind>[
  BurstKind.mine,
  BurstKind.senrin,
  BurstKind.kiku,
  BurstKind.botan,
  BurstKind.ring,
  BurstKind.crossette,
  BurstKind.willowRing,
  BurstKind.strobe,
];
final BurstSpec _dissolveSpark = burstPreset(BurstKind.botan).copyWith(
  count: 10,
  radius: 0.03,
  duration: 0.65,
  colors: const <int>[0, 1, 2],
  trail: 0.25,
  twinkle: 0.6,
);

/// 最后一句唱完前多少秒开始预建片尾卡（folia `PREBUILD_SECONDS`）。
const double _creditsPrebuild = 4;

/// 全屏辉光的三层模糊（σ 逻辑像素，权重）：folia 5 级金字塔（每级纹素翻倍，同级权重 0.85，最小一级 1）按宽度折成三层。
const List<(double, double)> _bloomLevels = <(double, double)>[
  (1.3, 1.7),
  (5, 1.7),
  (13.6, 1),
];

/// 全屏辉光的亮部提取：folia 下采样第一级的阈值 0.5 + 软膝 0.3（按最大通道）用线性 `0.9·c − 0.405` 逼近，
/// 放大 2 倍免得 8 位截断（叠回时乘 0.5），再乘色调 [1, 0.95, 0.98]。
const ui.ColorFilter _bloomExtract = ui.ColorFilter.matrix(<double>[
  1.8, 0, 0, 0, -0.81 * 255, //
  0, 1.8 * 0.95, 0, 0, -0.81 * 255 * 0.95, //
  0, 0, 1.8 * 0.98, 0, -0.81 * 255 * 0.98, //
  0, 0, 0, 1, 0,
]);

int _particleBudget(HanabiQuality q) => switch (q) {
  HanabiQuality.full => 6000,
  HanabiQuality.balanced => 3600,
  HanabiQuality.low => 1800,
};

// ─── 镜头装配 ───────────────────────────────────────────────────────────

class _ShotRig {
  _ShotRig({
    required this.shot,
    required this.profile,
    required this.palette,
    required this.timing,
    required this.text,
    required this.originX,
    required this.originY,
  });

  final HanabiShot shot;
  final HanabiProfile profile;
  final HanabiPalette palette;
  final ShotTiming timing;
  final HanabiText? text;

  /// 镜头容器原点（文字区中心）在画面里的位置（不含世界上升）。
  final double originX;
  final double originY;
  List<BurstPlan> bursts = <BurstPlan>[];
  List<LaunchEvent> launches = <LaunchEvent>[];

  /// 主烟花（拼贴的图标贴纸用；间奏为全部连发，folia planShotEvents 的 mains）。
  List<BurstEvent> mains = <BurstEvent>[];
  List<HanabiOrnament> back = <HanabiOrnament>[];
  List<HanabiOrnament> front = <HanabiOrnament>[];
  double lifeStart = 0;
  double lifeEnd = 0;

  void dispose() => text?.dispose();
}

/// 一拍的烟花放进了哪个镜头（folia `BeatPlaced`）。
class _BeatPlaced {
  const _BeatPlaced(this.shot, this.burst, this.launch);
  final int shot;
  final BurstPlan burst;
  final LaunchEvent? launch;
}

class _ParagraphRig {
  _ParagraphRig(
    this.paragraph,
    this.seed,
    this.timeline,
    this.shots,
    this.lastUsed,
  );
  final HanabiParagraph paragraph;

  /// 场景单元的种子（folia `${program.seed}:${paragraph.id}`）：镜头的字、烟花事件、装饰件、旋转与随拍开花都从它派生。
  final String seed;
  final HanabiTimeline timeline;
  final List<_ShotRig> shots;
  double lastUsed;

  /// 「随拍开花」每拍算一次就缓存（按拍的毫秒），换节拍表或强度时清掉。
  final Map<int, _BeatPlaced?> beats = <int, _BeatPlaced?>{};
  List<HanabiBeatEvent>? beatsFrom;
  double beatsStrength = -1;

  /// 环境层 + 拼贴层（hanabi_collage_decor.dart），按 [decorKey] 懒建。
  HanabiUnitDecor? decor;
  Object? decorKey;

  void dispose() {
    for (final _ShotRig s in shots) {
      s.dispose();
    }
    decor?.dispose();
    decor = null;
  }
}

/// 整首歌一份。
class HanabiScene {
  HanabiScene({required this.program, this.title, this.artist, this.album})
    : sprites = HanabiSprites.create();

  final HanabiProgram program;
  final String? title;
  final String? artist;
  final String? album;
  final HanabiSprites sprites;
  final SparkBatch _batch = SparkBatch();
  final Map<int, _ParagraphRig> _rigs = <int, _ParagraphRig>{};
  Object? _rigKey;
  final HanabiOverlay _overlay = HanabiOverlay();
  _CreditsRig? _credits;
  Object? _creditsKey;
  bool _disposed = false;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final _ParagraphRig r in _rigs.values) {
      r.dispose();
    }
    _rigs.clear();
    _credits?.dispose();
    _credits = null;
    _overlay.dispose();
    sprites.dispose();
  }

  int get builtParagraphs => _rigs.length;

  // ── 调色 ──

  HanabiTheme _paperTheme(HanabiFrame f) =>
      f.settings.sky >= 0.5 && !f.settings.textOnly
      ? HanabiTheme(
          primary: f.theme.primary,
          accent: f.theme.accent,
          secondary: f.theme.secondary,
          background: 0x0b0d24,
        )
      : f.theme;

  // ── 装配 ──

  _ParagraphRig _rigFor(int index, Size size, HanabiFrame f) {
    final Object key = Object.hash(
      size,
      f.settings.rigKey,
      f.motion,
      f.fontScale,
      f.theme.primary,
      f.theme.accent,
      f.theme.secondary,
      f.theme.background,
      f.baseStyle.fontFamily,
      f.baseStyle.fontWeight,
      f.intensityMotion,
      f.keywordKey,
    );
    if (key != _rigKey) {
      for (final _ParagraphRig r in _rigs.values) {
        r.dispose();
      }
      _rigs.clear();
      _rigKey = key;
    }
    final _ParagraphRig rig = _rigs.putIfAbsent(
      index,
      () => _buildParagraph(index, size, f),
    );
    rig.lastUsed = f.time;
    return rig;
  }

  void _evict(double time, Set<int> keep) {
    final List<int> drop = <int>[
      for (final MapEntry<int, _ParagraphRig> e in _rigs.entries)
        if (!keep.contains(e.key)) e.key,
    ];
    for (final int i in drop) {
      _rigs.remove(i)?.dispose();
    }
  }

  _ParagraphRig _buildParagraph(int index, Size size, HanabiFrame f) {
    final HanabiParagraph paragraph = program.paragraphs[index];
    final HanabiSettings s = f.settings;
    final double w = size.width;
    final double h = size.height;
    final double unit = math.min(w, h);
    final bool graphics = f.motion && !s.textOnly;
    final double textMotion = f.motion ? math.max(0, s.textMotion) : 0;
    final HanabiTheme paperTheme = _paperTheme(f);
    final String unitSeed = '${program.seed}:${paragraph.id}';
    final List<HanabiShot> shots = paragraph.shots;
    final List<HanabiLine?> lines = <HanabiLine?>[
      for (final HanabiShot shot in shots) program.shotLine(shot),
    ];
    final List<TimelineShot> timelineShots = <TimelineShot>[];
    for (int i = 0; i < shots.length; i++) {
      final HanabiLine? line = lines[i];
      double? firstSung;
      double? lastSungEnd;
      if (line != null) {
        for (int c = 0; c < line.chars.length; c++) {
          if (line.chars[c].trim().isEmpty) continue;
          firstSung = math.min(firstSung ?? double.infinity, line.charStart[c]);
          lastSungEnd = math.max(
            lastSungEnd ?? double.negativeInfinity,
            line.charEnd[c],
          );
        }
      }
      timelineShots.add(
        TimelineShot(
          startTime: shots[i].startTime,
          endTime: shots[i].endTime,
          firstSung: firstSung,
          lastSungEnd: lastSungEnd,
          isBridge: shots[i].isBridge,
          camera: hanabiProfileOf(shots[i].kind).camera,
        ),
      );
    }
    final double spinAmount = graphics ? math.max(0, s.spin) : 0;
    final SpinPlan spin = planSpin(
      <double>[
        for (final HanabiShot shot in shots) shot.endTime - shot.startTime,
      ],
      amount: spinAmount,
      direction: hanabiSpinDirection(program.seed),
      random: hanabiRng('$unitSeed:spin'),
    );
    final HanabiTimeline timeline = buildTimeline(
      timelineShots,
      unitEnd: paragraph.endTime,
      height: h,
      // 只画字（仅显示歌词文字）时字停在文字区里，不随世界上漂（folia graphicsOn）。
      riseSpeed: graphics ? math.max(0, s.riseSpeed) : 0,
      motion: textMotion * f.intensityMotion,
      exitStart: paragraph.transitionOut?.startTime,
      spinAngles: spin.angles,
      spinDrift: spin.drift,
    );
    final List<_ShotRig> rigs = <_ShotRig>[];
    for (int i = 0; i < shots.length; i++) {
      final HanabiShot shot = shots[i];
      final HanabiProfile profile = hanabiProfileOf(shot.kind);
      final HanabiPalette palette = resolveHanabiPalette(
        profile.palette,
        paperTheme,
        s.colorMode,
      );
      final ShotTiming timing = timeline.shots[i];
      final HanabiLine? line = lines[i];
      final HanabiText? text = line == null
          ? null
          : HanabiText(
              line: line,
              spec: profile.text.copyWith(
                heroSize: profile.text.heroSize * f.fontScale,
              ),
              palette: palette,
              regionWidth: profile.region.w * w,
              regionHeight: profile.region.h * h,
              unit: unit,
              seed: '$unitSeed:${shot.id}:text',
              enterAt: timing.enterAt,
              exitAt: timing.exitAt,
              exitDuration: timing.exitDuration,
              motion: textMotion,
              blockOpacity: clamp01(s.blockOpacity),
              baseStyle: f.baseStyle,
              keywordColor: f.keywordColor,
            );
      final _ShotRig rig = _ShotRig(
        shot: shot,
        profile: profile,
        palette: palette,
        timing: timing,
        text: text,
        originX: profile.region.cx * w,
        originY: profile.region.cy * h,
      );
      if (graphics) _planEvents(rig, i, w, h, unit, s, timeline, unitSeed);
      // 装饰件：间奏镜头（没有字）也照常挂，布点按文字区、没有字位置（folia buildRig）。
      if (graphics && s.ornamentAmount > 0) {
        final LayoutRect bounds =
            text?.bounds ??
            LayoutRect(
              -profile.region.w * w / 2,
              -profile.region.h * h / 2,
              profile.region.w * w,
              profile.region.h * h,
            );
        final List<GlyphAnchor> Function(double time) anchorsAt =
            text?.anchors ?? _noAnchors;
        for (int k = 0; k < profile.ornaments.length; k++) {
          final OrnamentSpec spec = profile.ornaments[k];
          final HanabiOrnament orn = HanabiOrnament(
            OrnamentKit(
              spec: spec,
              palette: palette,
              width: w,
              height: h,
              seed: '$unitSeed:${shot.id}:ornament$k',
              bounds: bounds,
              anchorsAt: anchorsAt,
              enterAt: timing.enterAt,
              exitAt: timing.exitAt,
              exitDuration: timing.exitDuration,
              amount: math.min(2, s.ornamentAmount),
            ),
          );
          (spec.layer == OrnamentLayer.back ? rig.back : rig.front).add(orn);
        }
      }
      // 可见区间（folia lifeStart / lifeEnd）：入场前 0.25 秒起，到退场、最后一朵烟花、最后一道尾迹都画完。
      double lifeEnd = timing.exitAt + timing.exitDuration + 0.3;
      for (final BurstPlan b in rig.bursts) {
        lifeEnd = math.max(lifeEnd, b.end + 0.05);
      }
      for (final LaunchEvent l in rig.launches) {
        lifeEnd = math.max(lifeEnd, launchEnd(l));
      }
      rig.lifeStart = math.min(timing.launchAt, timing.enterAt) - 0.25;
      rig.lifeEnd = lifeEnd;
      rigs.add(rig);
    }
    return _ParagraphRig(paragraph, unitSeed, timeline, rigs, 0);
  }

  static List<GlyphAnchor> _noAnchors(double time) => const <GlyphAnchor>[];

  void _planEvents(
    _ShotRig rig,
    int index,
    double w,
    double h,
    double unit,
    HanabiSettings s,
    HanabiTimeline timeline,
    String unitSeed,
  ) {
    final HanabiShot shot = rig.shot;
    final HanabiProfile profile = rig.profile;
    final ShotTiming timing = rig.timing;
    final HanabiRegion region = profile.region;
    final HanabiRng random = hanabiRng('$unitSeed:${shot.id}:$index:events');
    final List<BurstEvent> bursts = <BurstEvent>[];
    final List<LaunchEvent> launches = <LaunchEvent>[];
    final String key = '$unitSeed:${shot.id}';
    // 画面坐标在 time 时刻对应的镜头容器坐标（folia screenToShot）：含镜头在世界里的高度与那一刻世界的上升。
    (double, double) locate(double sx, double sy, double time) =>
        _screenToShot(rig, timeline, sx, sy, time);

    void launchTo(double x, double y, double arrive, String k) {
      final double at = arrive - kLaunchDuration;
      final double bottom = locate(0, h * 1.03, at).$2;
      launches.add(
        LaunchEvent(
          fromX: x + (random() - 0.5) * w * 0.08,
          fromY: math.max(bottom, y + h * 0.2),
          toX: x,
          toY: y,
          at: at,
          duration: kLaunchDuration,
          color: rig.palette.glow,
          seed: '$key:$k:launch',
        ),
      );
    }

    (double, double) shape(BurstSpec spec) {
      final BurstKind k = spec.kind;
      if (k == BurstKind.ring ||
          k == BurstKind.willowRing ||
          k == BurstKind.heart ||
          k == BurstKind.star) {
        final double squash = k == BurstKind.ring ? 0.4 + random() * 0.5 : 1;
        return (squash, (random() - 0.5) * 0.6);
      }
      return (1, 0);
    }

    if (shot.isBridge) {
      final double from = timing.start + 0.15;
      final double duration = math.max(0, timing.end - 0.3 - from);
      final int count = clampD(
        (duration / 0.75).roundToDouble(),
        1,
        10,
      ).toInt();
      final List<BurstKind> kinds = <BurstKind>[
        if (profile.burst != null) profile.burst!.kind,
        ..._bridgeKinds,
      ];
      for (int k = 0; k < count; k++) {
        final double at =
            from +
            (count == 1 ? 0 : (k / (count - 1)) * duration * 0.85) +
            random() * 0.12;
        final BurstKind kind =
            kinds[(random() * kinds.length).floor() % kinds.length];
        final BurstSpec spec = burstPreset(kind, <int>[
          k % 5,
          (k + 1) % 5,
          (k + 2) % 5,
        ]);
        if (kind == BurstKind.mine) {
          final (double x, double y) = locate(
            w * (0.2 + random() * 0.6),
            h * 0.94,
            at,
          );
          bursts.add(
            BurstEvent(
              x: x,
              y: y,
              at: at,
              spec: spec,
              seed: '$key:b$k',
              scale: 0.8 + random() * 0.3,
            ),
          );
          continue;
        }
        final (double x, double y) = locate(
          w * (0.15 + random() * 0.7),
          h * (0.14 + random() * 0.34),
          at,
        );
        final double scale = 0.55 + random() * 0.4;
        final (double squash, double rotation) = shape(spec);
        bursts.add(
          BurstEvent(
            x: x,
            y: y,
            at: at,
            spec: spec,
            seed: '$key:b$k',
            scale: scale,
            squash: squash,
            rotation: rotation,
          ),
        );
        if (s.launches) launchTo(x, y, at, 'b$k');
      }
    } else {
      final HanabiText? text = rig.text;
      final LayoutRect bounds =
          text?.bounds ??
          LayoutRect(
            -region.w * w / 2,
            -region.h * h / 2,
            region.w * w,
            region.h * h,
          );
      final double centerX = bounds.cx;
      final double centerY = bounds.cy;
      final BurstSpec? main = profile.burst;
      final bool withLaunch = profile.launch && s.launches;
      if (main != null) {
        final double radius = main.radius * unit;
        final double at = timing.enterAt;
        final double minY = h * 0.12 - region.cy * h;
        final double maxX = w * 0.42;
        final List<(double, double, double)> points =
            <(double, double, double)>[];
        if (main.kind == BurstKind.mine) {
          final List<double> xs = profile.burstAt == BurstAt.sides
              ? <double>[0.25, 0.75]
              : <double>[0.3 + random() * 0.4];
          for (int k = 0; k < xs.length; k++) {
            points.add((
              xs[k] * w - region.cx * w,
              h * 0.94 - region.cy * h,
              at + k * 0.15,
            ));
          }
        } else if (profile.burstAt == BurstAt.behind) {
          points.add((
            centerX + (random() - 0.5) * bounds.width * 0.15,
            centerY - radius * 0.15,
            at,
          ));
        } else if (profile.burstAt == BurstAt.above) {
          points.add((
            centerX + (random() - 0.5) * bounds.width * 0.3,
            math.max(minY, bounds.y - radius * 0.45),
            at,
          ));
        } else if (profile.burstAt == BurstAt.sides) {
          final double dx = math.min(maxX, bounds.width / 2 + radius * 0.35);
          final double y = math.max(minY, centerY - radius * 0.3);
          points
            ..add((centerX - dx, y, at))
            ..add((centerX + dx, y, at + 0.15));
        } else {
          // sky：画面上方随机的高处，按镜头定格时（入场后 0.6 秒）的画面换算。
          final (double x, double y) = locate(
            w * (0.2 + random() * 0.6),
            h * (0.12 + random() * 0.22),
            timing.enterAt + 0.6,
          );
          points.add((x, y, at));
        }
        for (int k = 0; k < points.length; k++) {
          final (double px, double py, double pat) = points[k];
          final double x = clampD(
            px,
            -region.cx * w + w * 0.06,
            w * (1 - region.cx) - w * 0.06,
          );
          final (double squash, double rotation) = shape(main);
          bursts.add(
            BurstEvent(
              x: x,
              y: py,
              at: pat,
              spec: main,
              seed: '$key:main$k',
              squash: squash,
              rotation: rotation,
            ),
          );
          if (withLaunch && main.kind != BurstKind.mine) {
            launchTo(x, py, pat, 'main$k');
          }
        }
      }
      if (text != null) {
        final List<GlyphAnchor> first = text.anchors(timing.enterAt);
        final List<int> glyphs = <int>[
          for (int k = 0; k < first.length; k++)
            if (!first[k].blank) k,
        ];
        final BurstSpec? sung = profile.sungBurst;
        if (sung != null) {
          final List<int> candidates = <int>[
            for (final int k in glyphs)
              if (first[k].sungAt >= timing.enterAt &&
                  first[k].sungAt < timing.exitAt)
                k,
          ];
          final List<int> chosen = thinList(candidates, _maxSungBursts);
          for (int n = 0; n < chosen.length; n++) {
            final int k = chosen[n];
            final List<GlyphAnchor> at = text.anchors(first[k].sungAt);
            final GlyphAnchor now = k < at.length ? at[k] : first[k];
            final List<int> colors = sung.colors.isNotEmpty
                ? <int>[
                    for (int j = 0; j < sung.colors.length; j++)
                      sung.colors[(j + n) % sung.colors.length],
                  ]
                : <int>[n];
            bursts.add(
              BurstEvent(
                x: now.x,
                y: now.y - now.size * 0.1,
                at: first[k].sungAt,
                spec: sung.copyWith(colors: colors),
                seed: '$key:sung$k',
                scale: clampD(now.size / (unit * 0.1), 0.6, 1.6),
              ),
            );
          }
        }
        if (profile.text.exit == ExitFx.dissolve) {
          final List<int> chosen = thinList(glyphs, _maxDissolveBursts);
          final double step = math.min(
            0.05,
            timing.exitDuration * 0.6 / math.max(chosen.length, 1),
          );
          for (int n = 0; n < chosen.length; n++) {
            final int k = chosen[n];
            final double at = timing.exitAt + n * step;
            final List<GlyphAnchor> anchors = text.anchors(at);
            if (k >= anchors.length) continue;
            bursts.add(
              BurstEvent(
                x: anchors[k].x,
                y: anchors[k].y,
                at: at,
                spec: _dissolveSpark,
                seed: '$key:dissolve$k',
              ),
            );
          }
        }
      }
    }
    bursts.sort((BurstEvent a, BurstEvent b) => a.at.compareTo(b.at));
    final double amount = math.max(0, s.sparkAmount);
    rig.bursts = <BurstPlan>[
      for (final BurstEvent e in bursts)
        planBurst(e, rig.palette, unit: unit, amount: amount),
    ];
    rig.launches = launches;
    rig.mains = shot.isBridge
        ? List<BurstEvent>.of(bursts)
        : <BurstEvent>[
            for (final BurstEvent e in bursts)
              if (e.seed.startsWith('$key:main')) e,
          ];
  }

  /// 画面坐标 (sx, sy) 在 time 时刻对应的镜头容器坐标（folia `screenToShot`；与 folia 一样不计镜头内运镜与世界旋转）。
  static (double, double) _screenToShot(
    _ShotRig shot,
    HanabiTimeline timeline,
    double sx,
    double sy,
    double time,
  ) => (
    sx - shot.originX,
    sy - (shot.originY + shot.timing.worldY + timeline.rise(time)),
  );

  // ── 随拍开花 ──

  /// 一拍的烟花开在那一拍所在的镜头里，位置按画面比例换算进镜头坐标；不在这一段里的拍不开。
  _BeatPlaced? _placeBeat(
    _ParagraphRig rig,
    HanabiBeatEvent event,
    double strength,
    Size size,
    HanabiFrame f,
  ) {
    final int key = (event.t * 1000).round();
    if (rig.beats.containsKey(key)) return rig.beats[key];
    _BeatPlaced? placed;
    final HanabiBeatShell? shell = resolveHanabiBeatShell(
      event,
      rig.seed,
      strength,
    );
    if (shell != null &&
        rig.shots.isNotEmpty &&
        event.t >= rig.paragraph.startTime &&
        event.t <= rig.paragraph.endTime) {
      final int index = rig.timeline.shotAt(event.t);
      final _ShotRig shot = rig.shots[index];
      final double w = size.width;
      final double h = size.height;
      final (double x, double y) = _screenToShot(
        shot,
        rig.timeline,
        shell.sx * w,
        shell.sy * h,
        event.t,
      );
      LaunchEvent? launch;
      if (shell.launch && f.settings.launches) {
        final double at = event.t - kLaunchDuration;
        final double bottom = _screenToShot(
          shot,
          rig.timeline,
          shell.sx * w,
          h * 1.03,
          at,
        ).$2;
        launch = LaunchEvent(
          fromX: x,
          fromY: math.max(bottom, y + h * 0.2),
          toX: x,
          toY: y,
          at: at,
          duration: kLaunchDuration,
          color: shot.palette.glow,
          seed: '${shell.seed}:launch',
        );
      }
      placed = _BeatPlaced(
        index,
        planBurst(
          BurstEvent(
            x: x,
            y: y,
            at: event.t,
            spec: shell.spec,
            seed: shell.seed,
          ),
          shot.palette,
          unit: math.min(w, h),
          amount: math.max(0, f.settings.sparkAmount),
        ),
        launch,
      );
    }
    rig.beats[key] = placed;
    return placed;
  }

  /// 这一帧在燃烧的拍（开花后 [kHanabiBeatShellLife] 秒内）与马上要升空到达的拍，按镜头分好。
  List<_BeatPlaced> _collectBeats(_ParagraphRig rig, Size size, HanabiFrame f) {
    final List<HanabiBeatEvent> events = f.beatEvents;
    final double strength = f.beatBursts;
    if (!f.motion || f.settings.textOnly || strength <= 0 || events.isEmpty) {
      return const <_BeatPlaced>[];
    }
    if (!identical(events, rig.beatsFrom) || strength != rig.beatsStrength) {
      rig.beats.clear();
      rig.beatsFrom = events;
      rig.beatsStrength = strength;
    }
    final double time = f.time;
    final double until = time + kLaunchDuration;
    final List<_BeatPlaced> out = <_BeatPlaced>[];
    for (
      int i = firstHanabiBeatAtOrAfter(events, time - kHanabiBeatShellLife);
      i < events.length && events[i].t <= until;
      i++
    ) {
      final _BeatPlaced? placed = _placeBeat(rig, events[i], strength, size, f);
      if (placed != null) out.add(placed);
    }
    return out;
  }

  // ── 画 ──

  /// 一帧。层级照 folia 运行时：夜空底 → 场景层（各段落场景，含环境层；套随拍推镜与全屏辉光）→ 片尾卡 → 画框。
  void paint(ui.Canvas canvas, Size size, HanabiFrame f) {
    if (_disposed || size.isEmpty) return;
    final HanabiSettings s = f.settings;
    final double w = size.width;
    final double h = size.height;
    final double unit = math.min(w, h);
    final double time = f.time;
    final bool graphics = f.motion && !s.textOnly;
    if (!s.textOnly) paintHanabiSky(canvas, size, f.theme, s.sky);

    // 片尾卡：纯音乐（没有 lyricEndTime）与没有任何歌曲信息时没有，歌词也不淡出（folia HanabiCreditsLayer）。
    final double? lyricEnd = _hasMeta ? program.lyricEndTime : null;
    final HanabiCreditsFrame credits = lyricEnd != null
        ? resolveHanabiCreditsFrame(time, lyricEnd)
        : const HanabiCreditsFrame(
            active: false,
            elapsed: 0,
            lyricAlpha: 1,
            lyricBlur: 0,
            posterAlpha: 0,
          );

    final HanabiSceneFrames frames = resolveHanabiSceneFrames(
      program,
      time,
      f.motion,
    );
    // 场景缓存：在画的段落 + 当前段 ±1（folia PixiSceneCache）。
    final int active = frames.activeIndex;
    final Set<int> keep = <int>{
      for (final HanabiLayerFrame l in frames.layers) l.index,
      if (active > 0) active - 1,
      if (active >= 0 && active + 1 < program.paragraphs.length) active + 1,
    };
    _evict(time, keep);
    for (final HanabiLayerFrame l in frames.layers) {
      _rigFor(l.index, size, f);
    }
    _prepareOne(size, f, active, lyricEnd);

    // 场景层录成一张 picture：先原样画，全屏辉光再拿它做亮部提取与模糊叠回去（片尾卡、画框、夜空不进）。
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final ui.Canvas layer = ui.Canvas(recorder);
    // 随拍推镜：整个场景层以画面中心推近、左右轻摆。
    final bool pulsed = graphics && (f.pulseScale != 1 || f.pulseRotation != 0);
    if (pulsed) {
      layer
        ..save()
        ..translate(w / 2, h / 2)
        ..rotate(f.pulseRotation)
        ..scale(f.pulseScale)
        ..translate(-w / 2, -h / 2);
    }

    // 各段落场景（交叉渐变时两个，上一段在下）。
    final double spinTurn = s.textOnly || s.spin <= 0
        ? 0
        : s.spin * hanabiSpinDirection(program.seed);
    _batch.reset(_particleBudget(s.quality));
    for (final HanabiLayerFrame l in frames.layers) {
      final HanabiTransitionFrame frame = l.frame;
      final double alpha = clamp01(frame.alpha * credits.lyricAlpha);
      if (alpha <= 0.002) continue;
      final double blur = f.motion
          ? math.max(frame.blur, credits.lyricBlur)
          : 0;
      final _ParagraphRig rig = _rigFor(l.index, size, f);
      final Rect bounds = Offset.zero & size;
      final bool needsLayer = alpha < 0.999 || blur > 0.3;
      if (needsLayer) {
        final Paint lp = Paint()..color = Color.fromRGBO(255, 255, 255, alpha);
        if (blur > 0.3) {
          // Pixi BlurFilter（strength = blur，quality 3：三遍 5 抽头核）的高斯等效 σ ≈ 0.58 × strength。
          lp.imageFilter = ui.ImageFilter.blur(
            sigmaX: blur * 0.58,
            sigmaY: blur * 0.58,
          );
        }
        layer.saveLayer(bounds, lp);
      }
      // 段落转场的旋转跟着「旋转」设置与整首歌的旋转方向走；仅显示歌词文字时不转（folia spinTurn）。
      layer.save();
      layer.translate(w / 2, h / 2 + frame.y * h);
      layer.rotate(frame.rotation * spinTurn);
      layer.scale(frame.scale);
      layer.translate(-w / 2, -h / 2);
      _paintParagraph(layer, size, rig, f, unit);
      layer.restore();
      if (needsLayer) layer.restore();
    }

    if (pulsed) layer.restore();
    final ui.Picture picture = recorder.endRecording();
    canvas.drawPicture(picture);

    // 全屏辉光：整体辉光 + 副歌辉光 × 副歌权重（folia applyScreenBloom，强度不到 0.01 时不画）。
    final double bloom = resolveHanabiScreenBloomStrength(
      s.bloom,
      s.chorusBloom,
      resolveHanabiChorusWeight(program.chorus, time),
    );
    if (bloom > 0.01) _paintScreenBloom(canvas, size, picture, bloom);
    picture.dispose();

    // 片尾卡（在场景层之上，不吃随拍推镜与全屏辉光）。
    if (lyricEnd != null && credits.posterAlpha > 0.002) {
      _batch.halo = math.min(2, math.max(0, s.glow));
      _creditsFor(size, f, lyricEnd).paint(
        canvas,
        size,
        time,
        credits.posterAlpha,
        _batch,
        sprites,
        f.motion,
      );
    }
    if (s.overlayFrame && !s.textOnly) {
      // 画框用 kawaii 调色（folia buildHanabiOverlay）。
      _overlay.paint(
        canvas,
        size,
        resolveHanabiPalette(PaletteRole.kawaii, _paperTheme(f), s.colorMode),
        f.baseStyle,
        1,
      );
    }
  }

  /// 一帧最多做一件贵的事（folia 运行时 renderFrame 的优先级）：画一个马上要出场的镜头的字形 →
  /// 预建下一段 → 预建片尾卡 → 预建上一段。没备好的到出场那一帧照样会补上，只是那一帧更重。
  void _prepareOne(Size size, HanabiFrame f, int active, double? lyricEnd) {
    final double time = f.time;
    for (final _ParagraphRig rig in _rigs.values) {
      for (final _ShotRig shot in rig.shots) {
        if (time > shot.lifeEnd || time < shot.lifeStart - _prepareAhead) {
          continue;
        }
        final HanabiText? text = shot.text;
        if (text != null && !text.prepared) {
          text.prepare();
          return;
        }
      }
    }
    final int next = active + 1;
    if (active >= 0 &&
        next < program.paragraphs.length &&
        !_rigs.containsKey(next)) {
      _rigFor(next, size, f);
      return;
    }
    if (lyricEnd != null &&
        time >= lyricEnd - _creditsPrebuild &&
        !(_credits != null &&
            _creditsKey == _creditsKeyOf(size, f, lyricEnd))) {
      _creditsFor(size, f, lyricEnd);
      return;
    }
    final int previous = active - 1;
    if (previous >= 0 && !_rigs.containsKey(previous)) {
      _rigFor(previous, size, f);
    }
  }

  /// 场景舞台的镜头内运镜（folia stage：推近、摆动、入场震动，绕画面中心）。
  void _applyCamera(
    ui.Canvas canvas,
    Size size,
    HanabiTimeline timeline,
    HanabiFrame f,
  ) {
    final double w = size.width;
    final double h = size.height;
    final CameraOffset cam = f.motion
        ? timeline.camera(f.time, h)
        : const CameraOffset(1, 0, 0, 0);
    canvas
      ..translate(w / 2 + cam.dx, h / 2 + cam.dy)
      ..rotate(cam.rotation)
      ..scale(cam.scale)
      ..translate(-w / 2, -h / 2);
  }

  /// 全屏辉光（folia `createBloomFilter`：阈值 0.5、软膝 0.3、5 级双线性金字塔、同级权重 0.85、色调 [1, 0.95, 0.98]）。
  /// 软膝亮部提取用一条线性色彩矩阵逼近（`0.9·c − 0.405`，在 c ≥ 0.5 与原曲线相差 < 0.03），
  /// 5 级逐级降 / 升采样折成三层宽度递增的高斯模糊，各层权重之和与金字塔一致（1 + 0.85 × 4）。
  void _paintScreenBloom(
    ui.Canvas canvas,
    Size size,
    ui.Picture picture,
    double strength,
  ) {
    final Rect bounds = Offset.zero & size;
    for (final (double sigma, double weight) in _bloomLevels) {
      // 提取矩阵把亮部放大了 2 倍（免得在 8 位里截断），这里乘回 0.5。
      final double alpha = clamp01(strength * weight * 0.5);
      if (alpha <= 0.002) continue;
      canvas.saveLayer(
        bounds,
        Paint()
          ..blendMode = BlendMode.plus
          ..color = Color.fromRGBO(255, 255, 255, alpha)
          ..imageFilter = ui.ImageFilter.compose(
            outer: ui.ImageFilter.blur(
              sigmaX: sigma,
              sigmaY: sigma,
              tileMode: TileMode.decal,
            ),
            inner: _bloomExtract,
          ),
      );
      canvas.drawPicture(picture);
      canvas.restore();
    }
  }

  bool get _hasMeta =>
      (title?.trim().isNotEmpty ?? false) ||
      (artist?.trim().isNotEmpty ?? false) ||
      (album?.trim().isNotEmpty ?? false);

  void _paintParagraph(
    ui.Canvas canvas,
    Size size,
    _ParagraphRig rig,
    HanabiFrame f,
    double unit,
  ) {
    final double w = size.width;
    final double h = size.height;
    final double time = f.time;
    final HanabiTimeline timeline = rig.timeline;
    canvas.save();
    // stage（镜头内运镜）→ spin（绕画面中心转 spin(t)）→ world（y = rise(t)）。
    _applyCamera(canvas, size, timeline, f);
    // 环境层（后）+ 网点底纹：在舞台里、世界外（folia scene.ts 层序）。
    final HanabiUnitDecor? decor = _decorFor(rig, size, f);
    final double rise = timeline.rise(time);
    decor?.paintBack(canvas, sprites, time, rise);
    canvas
      ..save()
      ..translate(w / 2, h / 2)
      ..rotate(timeline.spin(time))
      ..translate(-w / 2, -h / 2 + rise);
    final List<_BeatPlaced> beats = _collectBeats(rig, size, f);
    for (int si = 0; si < rig.shots.length; si++) {
      final _ShotRig shot = rig.shots[si];
      if (time < shot.lifeStart ||
          time > math.max(shot.lifeEnd, decor?.shotLifeEnd(si) ?? 0)) {
        continue;
      }
      final ShotTiming timing = shot.timing;
      final HanabiText? text = shot.text;
      if (text != null && !text.prepared) text.prepare();
      canvas.save();
      canvas.translate(w / 2, h / 2 + timing.worldY);
      canvas.rotate(-timing.spin);
      canvas.translate(-w / 2 + shot.originX, -h / 2 + shot.originY);
      // 烟花（含随拍开花）
      final List<_BeatPlaced> shotBeats = <_BeatPlaced>[
        for (final _BeatPlaced b in beats)
          if (b.shot == si) b,
      ];
      if (shot.bursts.isNotEmpty ||
          shot.launches.isNotEmpty ||
          shotBeats.isNotEmpty) {
        for (final LaunchEvent l in <LaunchEvent>[
          ...shot.launches,
          for (final _BeatPlaced b in shotBeats) ?b.launch,
        ]) {
          if (time >= l.at && time <= launchEnd(l)) {
            drawLaunch(l, time, unit, _batch);
          }
        }
        final List<BurstPlan> active = <BurstPlan>[
          for (final BurstPlan b in shot.bursts)
            if (time >= b.at && time <= b.end) b,
          for (final _BeatPlaced b in shotBeats)
            if (time >= b.burst.at && time <= b.burst.end) b.burst,
        ];
        if (active.isNotEmpty) drawBursts(active, time, _batch);
        _batch.flush(canvas, sprites);
      }
      for (final HanabiOrnament o in shot.back) {
        o.paint(canvas, time);
      }
      decor?.paintShotBack(canvas, si, time);
      if (text != null) {
        text.paintBlocks(canvas, time);
        text.paintGlyphs(canvas, time);
      }
      for (final HanabiOrnament o in shot.front) {
        o.paint(canvas, time);
      }
      decor?.paintShotFront(canvas, si, time);
      canvas.restore();
    }
    canvas.restore();
    // 环境层（前）+ 左缘竖胶片。
    decor?.paintFront(canvas, sprites, time, rise);
    canvas.restore();
  }

  /// 段落的环境层与拼贴层（folia scene.ts 的 ambient / unitCollage / 每镜头 collage）；
  /// 密度、拼贴量、画质变了重建。只在出图形时有（folia graphicsOn）。
  HanabiUnitDecor? _decorFor(_ParagraphRig rig, Size size, HanabiFrame f) {
    final HanabiSettings s = f.settings;
    if (!f.motion || s.textOnly) return null;
    final double density =
        math.min(2, math.max(0, s.ambient)) *
        (s.quality == HanabiQuality.low ? 0.6 : 1);
    final double collage = math.min(2, math.max(0, s.collage));
    final Object key = Object.hash(density, collage, title);
    if (rig.decorKey == key) return rig.decor;
    rig.decor?.dispose();
    rig.decorKey = key;
    final HanabiParagraph paragraph = rig.paragraph;
    final String? songTitle = title?.trim();
    final String? songArtist = artist?.trim();
    final HanabiUnitDecor decor = HanabiUnitDecor(
      unitSeed: rig.seed,
      size: size,
      shots: <HanabiDecorShot>[
        for (final _ShotRig shot in rig.shots)
          HanabiDecorShot(
            id: shot.shot.id,
            profile: shot.profile,
            isBridge: shot.shot.isBridge,
            timing: shot.timing,
            palette: shot.palette,
            line: program.shotLine(shot.shot),
            textBounds: shot.text?.bounds,
            mains: shot.mains,
            launches: shot.launches,
          ),
      ],
      rise: rig.timeline.rise,
      startTime: paragraph.startTime,
      endTime: paragraph.endTime,
      ambientDensity: density,
      collageAmount: collage,
      motifs: hanabiCollageMotifs(songTitle),
      opening: paragraph.index == 0 && songTitle != null && songTitle.isNotEmpty
          ? CollageOpening(
              songTitle,
              songArtist == null || songArtist.isEmpty ? null : songArtist,
            )
          : null,
      fallbackFont: f.baseStyle.fontFamily,
    );
    return rig.decor = decor;
  }

  /// 片尾卡的烘焙输入：尺寸、主题（调色板）、字体、tuning、歌词结束时刻；变了就作废重建（folia invalidate）。
  Object _creditsKeyOf(Size size, HanabiFrame f, double lyricEnd) =>
      Object.hash(
        size,
        f.baseStyle.fontFamily,
        f.baseStyle.fontWeight,
        f.settings.rigKey,
        f.settings.collage,
        f.motion,
        f.theme.primary,
        f.theme.accent,
        f.theme.secondary,
        f.theme.background,
        lyricEnd,
      );

  _CreditsRig _creditsFor(Size size, HanabiFrame f, double lyricEnd) {
    final Object key = _creditsKeyOf(size, f, lyricEnd);
    final _CreditsRig? existing = _credits;
    if (existing != null && key == _creditsKey) return existing;
    existing?.dispose();
    _creditsKey = key;
    return _credits = _CreditsRig(
      size: size,
      start: lyricEnd,
      title: title?.trim() ?? '',
      artist: artist?.trim() ?? '',
      album: album?.trim() ?? '',
      palette: resolveHanabiPalette(
        PaletteRole.kawaii,
        _paperTheme(f),
        f.settings.colorMode,
      ),
      baseStyle: f.baseStyle,
      motion: f.motion ? math.max(0, f.settings.textMotion) : 0,
      blockOpacity: clamp01(f.settings.blockOpacity),
      sparkAmount: f.settings.sparkAmount,
      collage: f.settings.textOnly ? 0 : f.settings.collage,
    );
  }
}

// ─── 片尾卡 ─────────────────────────────────────────────────────────────

const double _bloomAt = 1.1;
const double _titleStart = 1.45;
const double _titleStep = 0.12;
const double _titleSpan = 2;
const TextSpec _titleSpec = TextSpec(
  layout: TextLayoutKind.center,
  heroSize: 0.11,
  emphasis: 0.2,
  tilt: 0,
  block: BlockStyle.band,
  enter: EnterFx.pop,
  sing: SingFx.color,
  exit: ExitFx.ascend,
  stagger: 0.05,
  outline: false,
  hardShadow: true,
);

class _CreditsRig {
  _CreditsRig({
    required Size size,
    required this.start,
    required String title,
    required this.artist,
    required this.album,
    required this.palette,
    required this.baseStyle,
    required double motion,
    required double blockOpacity,
    required double sparkAmount,
    required double collage,
  }) {
    final double w = size.width;
    final double h = size.height;
    final double unit = math.min(w, h);
    final List<String> chars = title.characters.toList();
    if (chars.isNotEmpty) {
      final double step = math.min(_titleStep, _titleSpan / chars.length);
      final double t0 = start + _titleStart;
      _title = HanabiText(
        line: HanabiLine(
          chars: chars,
          charStart: <double>[
            for (int i = 0; i < chars.length; i++) t0 + i * step,
          ],
          charEnd: <double>[
            for (int i = 0; i < chars.length; i++) t0 + (i + 1) * step,
          ],
          startTime: t0,
          endTime: t0 + chars.length * step + 0.4,
        ),
        // folia 的片尾卡不吃歌词字号倍率（HanabiCreditsLayer 没有传 fontScale）。
        spec: _titleSpec,
        palette: palette,
        regionWidth: 0.72 * w,
        regionHeight: 0.26 * h,
        unit: unit,
        seed: 'hanabi:credits:title',
        enterAt: start + _bloomAt - 0.1,
        // 片尾卡一直停在最后一帧，字不退场。
        exitAt: start + 1e6,
        exitDuration: 1,
        motion: motion,
        blockOpacity: blockOpacity,
        baseStyle: baseStyle,
      );
      _titleDone =
          _titleStart + math.min(_titleSpan, _titleStep * chars.length);
    }
    // 尾迹 0.45 秒从底边升起，1.1 秒在曲名上方开金冠，随后两侧千輪、最后一朵双层（folia credits.ts）。
    final List<(BurstSpec, double, double, double, double, String)> plan =
        <(BurstSpec, double, double, double, double, String)>[
          (
            burstPreset(BurstKind.kamuro, const <int>[
              0,
              1,
              3,
            ]).copyWith(count: 150, radius: 0.46, duration: 4.2),
            0.5,
            0.34,
            _bloomAt,
            1,
            'crown',
          ),
          (
            burstPreset(BurstKind.senrin, const <int>[1, 2, 3]),
            0.2,
            0.3,
            _bloomAt + 0.55,
            0.8,
            'left',
          ),
          (
            burstPreset(BurstKind.senrin, const <int>[2, 3, 0]),
            0.8,
            0.27,
            _bloomAt + 0.8,
            0.8,
            'right',
          ),
          (
            burstPreset(BurstKind.willowRing, const <int>[3, 0, 1]),
            0.5,
            0.22,
            _bloomAt + 2.2,
            0.9,
            'finale',
          ),
        ];
    for (final (
          int k,
          (
            BurstSpec spec,
            double x,
            double y,
            double at,
            double scale,
            String name,
          ),
        )
        in plan.indexed) {
      _bursts.add(
        planBurst(
          BurstEvent(
            x: x * w,
            y: y * h,
            at: start + at,
            spec: spec,
            seed: 'hanabi:credits:$name',
            scale: scale,
          ),
          palette,
          unit: unit,
          amount: math.max(0, sparkAmount),
        ),
      );
      _launches.add(
        LaunchEvent(
          fromX: x * w + (k.isEven ? -1 : 1) * w * 0.02,
          fromY: h * 1.03,
          toX: x * w,
          toY: y * h,
          at: start + at - kLaunchDuration,
          duration: kLaunchDuration,
          color: palette.glow,
          seed: 'hanabi:credits:launch$k',
        ),
      );
    }
    if (collage > 0) _planCollage(w, h, unit);
  }

  /// 片尾卡的拼贴（folia credits.ts，tuning.collage > 0 时）：下方一条电影胶片、上方一条蕾丝花边、
  /// 金冠开花时蹦出的图标、曲名四角的贴纸、往上飘的贴纸气球。坐标是画面坐标，时间是片尾卡内的时间，一直停在最后一帧。
  void _planCollage(double w, double h, double unit) {
    _collageCache = HanabiCollageCache(fallbackFont: baseStyle.fontFamily);
    const double stay = 1e6;
    StripItem band(
      StripStyle style,
      double y,
      double rotation,
      int color,
      double at,
      int from,
    ) {
      final bool film = style == StripStyle.film;
      return StripItem(
        style: style,
        x: w / 2,
        y: y,
        length: math.sqrt(w * w + h * h) * 1.25,
        thickness: math.max(18, unit * (film ? 0.075 : 0.06)),
        rotation: rotation,
        color: color,
        speed: from * unit * (film ? 0.12 : 0.05),
        from: from,
        at: at,
        exitAt: stay,
        exitDuration: 1,
      );
    }

    const List<StickerShape> shapes = <StickerShape>[
      StickerShape.heart,
      StickerShape.star,
      StickerShape.ribbon,
      StickerShape.sparkle,
    ];
    final int candy = kCollageCandy.length;
    _collagePlan = CollagePlan(null, <CollageItem>[
      band(
        StripStyle.film,
        h * 0.85,
        0.06,
        kCollageCandy[0],
        _titleStart + 0.4,
        -1,
      ),
      band(
        StripStyle.lace,
        h * 0.13,
        -0.05,
        kCollageCandy[3],
        _titleStart + 0.7,
        1,
      ),
      PopItem(
        x: w * 0.72,
        y: h * 0.22,
        icon: kHanabiFallbackIcon,
        color: kCollageIconInks[0],
        size: unit * 0.12,
        rotation: 0.16,
        at: _bloomAt + 0.04,
        duration: 1.4,
      ),
      for (int k = 0; k < shapes.length; k++)
        StickerItem(
          shape: shapes[k],
          x:
              w / 2 +
              (k == 0 || k == 3 ? -1 : 1) * math.min(w * 0.38, unit * 0.62),
          y: h * 0.5 + (k < 2 ? -1 : 1) * unit * 0.1,
          size: unit * 0.08,
          rotation: (k.isEven ? -1 : 1) * 0.25,
          color: kCollageCandy[(k + 3) % candy],
          label: null,
          layer: CollageLayer.front,
          at: _titleStart + 0.5 + k * 0.12,
          exitAt: stay,
          exitDuration: 1,
        ),
      for (int k = 0; k < 6; k++)
        FloaterItem(
          shape: shapes[k % shapes.length],
          x: w * (0.12 + ((k * 0.37) % 1) * 0.76),
          y: h * 1.08,
          rise: h * 1.3,
          size: unit * (0.05 + (k % 3) * 0.012),
          color: kCollageCandy[k % candy],
          at: 2.4 + k * 0.9,
          duration: 4.2,
          sway: unit * 0.03,
        ),
    ]);
  }

  HanabiCollageCache? _collageCache;
  CollagePlan? _collagePlan;

  /// 拼贴的时间：贴纸气球一轮飘完再从头来（片尾卡可能停很久）。
  double _collageTime(double elapsed) {
    final double t = math.max(0, elapsed);
    return t < 8 ? t : 2.4 + ((t - 2.4) % 5.6);
  }

  final double start;
  final String artist;
  final String album;
  final HanabiPalette palette;
  final TextStyle baseStyle;
  HanabiText? _title;
  double _titleDone = 1.2;
  final List<BurstPlan> _bursts = <BurstPlan>[];
  final List<LaunchEvent> _launches = <LaunchEvent>[];
  final Map<String, TextPainter> _painters = <String, TextPainter>{};

  TextPainter _detail(
    String text,
    double size,
    double spacing,
    double maxWidth,
  ) => _painters.putIfAbsent(
    '$text|$size|$maxWidth',
    () => TextPainter(
      text: TextSpan(
        text: text,
        style: baseStyle.copyWith(
          fontSize: size,
          letterSpacing: size * spacing,
          color: rgbColor(palette.paper),
          fontWeight: baseStyle.fontWeight ?? FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout(maxWidth: maxWidth),
  );

  void paint(
    ui.Canvas canvas,
    Size size,
    double time,
    double alpha,
    SparkBatch batch,
    HanabiSprites sprites,
    bool graphics,
  ) {
    if (alpha <= 0.003) return;
    final double w = size.width;
    final double h = size.height;
    final double unit = math.min(w, h);
    final double elapsed = time - start;
    canvas.saveLayer(
      Offset.zero & size,
      Paint()..color = Color.fromRGBO(255, 255, 255, alpha),
    );
    if (graphics) {
      for (final LaunchEvent l in _launches) {
        if (time >= l.at && time <= launchEnd(l)) {
          drawLaunch(l, time, unit, batch);
        }
      }
      final List<BurstPlan> active = <BurstPlan>[
        for (final BurstPlan b in _bursts)
          if (time >= b.at && time <= b.end) b,
      ];
      if (active.isNotEmpty) drawBursts(active, time, batch);
      batch.flush(canvas, sprites);
    }
    final HanabiCollageCache? collageCache = _collageCache;
    final CollagePlan? collagePlan = _collagePlan;
    final bool collageOn =
        graphics && collageCache != null && collagePlan != null;
    if (collageOn) {
      paintCollageItems(
        canvas,
        collageCache,
        collagePlan,
        CollageLayer.back,
        _collageTime(elapsed),
      );
    }
    final HanabiText? title = _title;
    if (title != null) {
      if (!title.prepared) title.prepare();
      canvas.save();
      canvas.translate(w / 2, h * 0.5);
      title.paintBlocks(canvas, time);
      title.paintGlyphs(canvas, time);
      canvas.restore();
    }
    final double size0 = math.max(13, 0.03 * h);
    void detail(
      String text,
      double y,
      double fontSize,
      double spacing,
      double delay,
    ) {
      if (text.isEmpty) return;
      final double k = smoothstep01((elapsed - delay) / 0.9);
      if (k <= 0.003) return;
      final TextPainter p = _detail(text, fontSize, spacing, w * 0.7);
      canvas.saveLayer(
        Offset.zero & size,
        Paint()..color = Color.fromRGBO(255, 255, 255, k * 0.92),
      );
      p.paint(
        canvas,
        Offset((w - p.width) / 2, y + (1 - k) * 0.02 * h - p.height / 2),
      );
      canvas.restore();
    }

    final double delay = _title != null ? _titleDone : 1.2;
    detail(artist.toUpperCase(), h * 0.66, size0, 0.3, delay);
    detail(album, h * 0.35, size0 * 0.8, 0.16, delay + 0.3);
    if (collageOn) {
      paintCollageItems(
        canvas,
        collageCache,
        collagePlan,
        CollageLayer.front,
        _collageTime(elapsed),
      );
    }
    canvas.restore();
  }

  void dispose() {
    _title?.dispose();
    _title = null;
    _collageCache?.dispose();
    _collageCache = null;
    for (final TextPainter p in _painters.values) {
      p.dispose();
    }
    _painters.clear();
  }
}
