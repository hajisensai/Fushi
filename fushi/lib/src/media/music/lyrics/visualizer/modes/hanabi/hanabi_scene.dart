/// 花火的场景（移植 folia `hanabi/scene.ts`、`credits.ts`、`hanabiScreenBloom.ts`）。
///
/// 节目单按段落建「装配」：每个镜头一套文字、烟花事件（主烟花、被唱到的字各一朵小花、碎成火花的退场、间奏连发）、
/// 装饰件；镜头挂在一条向上走的世界里，世界绕画面中心慢慢转，段落之间套转场帧。装配只在段落快出场时建，离场就放掉。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_ambient.dart';
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
  _ParagraphRig(this.paragraph, this.timeline, this.shots, this.lastUsed);
  final HanabiParagraph paragraph;
  final HanabiTimeline timeline;
  final List<_ShotRig> shots;
  double lastUsed;

  /// 「随拍开花」每拍算一次就缓存（按拍的毫秒），换节拍表或强度时清掉。
  final Map<int, _BeatPlaced?> beats = <int, _BeatPlaced?>{};
  List<HanabiBeatEvent>? beatsFrom;
  double beatsStrength = -1;

  void dispose() {
    for (final _ShotRig s in shots) {
      s.dispose();
    }
  }
}

/// 整首歌一份。
class HanabiScene {
  HanabiScene({
    required this.program,
    required String seed,
    this.title,
    this.artist,
    this.album,
  }) : _seed = seed,
       sprites = HanabiSprites.create();

  final HanabiProgram program;
  final String _seed;
  final String? title;
  final String? artist;
  final String? album;
  final HanabiSprites sprites;
  final SparkBatch _batch = SparkBatch();
  final Map<int, _ParagraphRig> _rigs = <int, _ParagraphRig>{};
  Object? _rigKey;
  HanabiAmbient? _ambient;
  Object? _ambientKey;
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
      random: hanabiRng('${program.seed}:p$index:spin'),
    );
    final HanabiTimeline timeline = buildTimeline(
      timelineShots,
      unitEnd: paragraph.endTime,
      height: h,
      riseSpeed: f.motion ? math.max(0, s.riseSpeed) : 0,
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
              seed: '${program.seed}:${shot.id}',
              enterAt: timing.enterAt,
              exitAt: timing.exitAt,
              exitDuration: timing.exitDuration,
              motion: textMotion,
              blockOpacity: s.blockOpacity,
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
      if (graphics) _planEvents(rig, i, w, h, unit, s);
      if (graphics && text != null && s.ornamentAmount > 0) {
        for (final OrnamentSpec spec in profile.ornaments) {
          final HanabiOrnament orn = HanabiOrnament(
            OrnamentKit(
              spec: spec,
              palette: palette,
              width: w,
              height: h,
              seed: '${program.seed}:${shot.id}',
              bounds: text.bounds,
              anchorsAt: text.anchors,
              enterAt: timing.enterAt,
              exitAt: timing.exitAt,
              exitDuration: timing.exitDuration,
              amount: s.ornamentAmount,
            ),
          );
          (spec.layer == OrnamentLayer.back ? rig.back : rig.front).add(orn);
        }
      }
      double lifeEnd = math.max(
        timing.exitAt + timing.exitDuration + 0.3,
        timing.end,
      );
      for (final BurstPlan b in rig.bursts) {
        lifeEnd = math.max(lifeEnd, b.end + 0.05);
      }
      for (final LaunchEvent l in rig.launches) {
        lifeEnd = math.max(lifeEnd, launchEnd(l));
      }
      double lifeStart = math.min(timing.launchAt, timing.enterAt) - 0.25;
      for (final LaunchEvent l in rig.launches) {
        lifeStart = math.min(lifeStart, l.at - 0.05);
      }
      rig.lifeStart = lifeStart;
      rig.lifeEnd = lifeEnd;
      rigs.add(rig);
    }
    return _ParagraphRig(paragraph, timeline, rigs, 0);
  }

  void _planEvents(
    _ShotRig rig,
    int index,
    double w,
    double h,
    double unit,
    HanabiSettings s,
  ) {
    final HanabiShot shot = rig.shot;
    final HanabiProfile profile = rig.profile;
    final ShotTiming timing = rig.timing;
    final HanabiRegion region = profile.region;
    final HanabiRng random = hanabiRng(
      '${program.seed}:${shot.id}:$index:events',
    );
    final List<BurstEvent> bursts = <BurstEvent>[];
    final List<LaunchEvent> launches = <LaunchEvent>[];
    final String key = '${program.seed}:${shot.id}';
    (double, double) locate(double sx, double sy) =>
        (sx - rig.originX, sy - rig.originY);

    void launchTo(double x, double y, double arrive, String k) {
      final double at = arrive - kLaunchDuration;
      final double bottom = h * 1.03 - rig.originY;
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
          final (double x, double y) = locate(
            w * (0.2 + random() * 0.6),
            h * (0.12 + random() * 0.22),
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
  }

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
      program.seed,
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
      final double x = shell.sx * w - shot.originX;
      final double y = shell.sy * h - shot.originY;
      LaunchEvent? launch;
      if (shell.launch && f.settings.launches) {
        final double bottom = h * 1.03 - shot.originY;
        launch = LaunchEvent(
          fromX: x,
          fromY: math.max(bottom, y + h * 0.2),
          toX: x,
          toY: y,
          at: event.t - kLaunchDuration,
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

  void paint(ui.Canvas canvas, Size size, HanabiFrame f) {
    if (_disposed || size.isEmpty) return;
    final HanabiSettings s = f.settings;
    final double w = size.width;
    final double h = size.height;
    final double unit = math.min(w, h);
    final double time = f.time;
    final bool graphics = f.motion && !s.textOnly;
    final HanabiPalette scenePalette = resolveHanabiPalette(
      PaletteRole.night,
      _paperTheme(f),
      s.colorMode,
    );

    if (!s.textOnly) paintHanabiSky(canvas, size, f.theme, s.sky);

    final double? lyricEnd = program.lyricEndTime;
    final HanabiCreditsFrame credits = lyricEnd != null && _hasMeta
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
    // 提前备好下一段。
    final Set<int> keep = <int>{
      for (final HanabiLayerFrame l in frames.layers) l.index,
    };
    final int next = frames.activeIndex + 1;
    if (next > 0 &&
        next < program.paragraphs.length &&
        program.paragraphs[next].startTime - time < _prepareAhead) {
      keep.add(next);
    }
    _evict(time, keep);
    double rise = 0;
    if (frames.activeIndex >= 0) {
      rise = _rigFor(frames.activeIndex, size, f).timeline.rise(time);
    }
    if (next > 0 && keep.contains(next)) {
      final _ParagraphRig upcoming = _rigFor(next, size, f);
      for (final _ShotRig shot in upcoming.shots) {
        if (shot.lifeStart - time < _prepareAhead) shot.text?.prepare();
      }
    }

    // 随拍推镜：整个场景层（环境、歌词、辉光）以画面中心推近、左右轻摆。
    final bool pulsed = graphics && (f.pulseScale != 1 || f.pulseRotation != 0);
    if (pulsed) {
      canvas
        ..save()
        ..translate(w / 2, h / 2)
        ..rotate(f.pulseRotation)
        ..scale(f.pulseScale)
        ..translate(-w / 2, -h / 2);
    }

    // 环境层（后）。
    final HanabiAmbient? ambient = graphics ? _ambientFor(f) : null;
    _batch.halo = graphics && s.quality != HanabiQuality.low
        ? math.max(0, s.glow)
        : 0;
    if (ambient != null) {
      _batch.reset(1 << 20);
      ambient.paintBack(_batch, size, time, rise, scenePalette);
      _batch.flush(canvas, sprites);
      if (s.collage > 0) {
        paintHanabiCollage(canvas, size, rise, scenePalette, s.collage);
      }
    }

    // 歌词层（录下来，副歌辉光再叠一遍）。
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final ui.Canvas layer = ui.Canvas(recorder);
    _batch.reset(_particleBudget(s.quality));
    for (final HanabiLayerFrame l in frames.layers) {
      final HanabiTransitionFrame frame = l.frame;
      final double alpha = clamp01(frame.alpha * credits.lyricAlpha);
      if (alpha <= 0.003) continue;
      final double blur = f.motion
          ? math.max(frame.blur, credits.lyricBlur)
          : 0;
      final _ParagraphRig rig = _rigFor(l.index, size, f);
      final Rect bounds = Offset.zero & size;
      final bool needsLayer = alpha < 0.999 || blur > 0.3;
      if (needsLayer) {
        final Paint lp = Paint()..color = Color.fromRGBO(255, 255, 255, alpha);
        if (blur > 0.3) {
          lp.imageFilter = ui.ImageFilter.blur(
            sigmaX: blur * 0.5,
            sigmaY: blur * 0.5,
          );
        }
        layer.saveLayer(bounds, lp);
      }
      layer.save();
      layer.translate(w / 2, h / 2 + frame.y * h);
      layer.rotate(frame.rotation);
      layer.scale(frame.scale);
      layer.translate(-w / 2, -h / 2);
      _paintParagraph(layer, size, rig, f, unit);
      layer.restore();
      if (needsLayer) layer.restore();
    }
    if (credits.posterAlpha > 0) {
      _creditsFor(size, f, lyricEnd!).paint(
        layer,
        size,
        time,
        credits.posterAlpha,
        _batch,
        sprites,
        graphics,
      );
    }
    final ui.Picture picture = recorder.endRecording();
    canvas.drawPicture(picture);
    final double bloom = graphics && s.quality != HanabiQuality.low
        ? resolveHanabiScreenBloomStrength(
            s.bloom,
            s.chorusBloom,
            resolveHanabiChorusWeight(program.chorus, time),
          )
        : 0;
    if (bloom > 0.02) {
      final double sigma =
          unit * (s.quality == HanabiQuality.full ? 0.014 : 0.009);
      canvas.saveLayer(
        Offset.zero & size,
        Paint()
          ..blendMode = BlendMode.plus
          ..color = Color.fromRGBO(255, 255, 255, clamp01(bloom * 0.45))
          ..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
      );
      canvas.drawPicture(picture);
      canvas.restore();
    }
    picture.dispose();

    // 环境层（前）。
    if (ambient != null) {
      _batch.reset(1 << 20);
      ambient.paintFront(_batch, size, time, rise, scenePalette);
      _batch.flush(canvas, sprites);
    }
    if (pulsed) canvas.restore();
    if (s.overlayFrame) {
      _overlay.paint(canvas, size, scenePalette, f.baseStyle, 1);
    }
  }

  bool get _hasMeta =>
      (title?.trim().isNotEmpty ?? false) ||
      (artist?.trim().isNotEmpty ?? false);

  HanabiAmbient _ambientFor(HanabiFrame f) {
    final double density =
        math.min(2, math.max(0, f.settings.ambient)) *
        (f.settings.quality == HanabiQuality.low ? 0.6 : 1);
    final Object key = density;
    final HanabiAmbient? existing = _ambient;
    if (existing != null && _ambientKey == key) return existing;
    _ambientKey = key;
    return _ambient = HanabiAmbient(
      seed: _seed,
      density: density,
      mood: _songMood(),
    );
  }

  HanabiMood _songMood() {
    double sum = 0;
    int n = 0;
    for (final HanabiParagraph p in program.paragraphs) {
      for (final HanabiShot s in p.shots) {
        sum += switch (hanabiProfileOf(s.kind).mood) {
          HanabiMood.quiet => 0.08,
          HanabiMood.neutral => 0.2,
          HanabiMood.loud => 0.35,
        };
        n++;
      }
    }
    final double avg = n == 0 ? 0.2 : sum / n;
    return avg < 0.14
        ? HanabiMood.quiet
        : (avg < 0.27 ? HanabiMood.neutral : HanabiMood.loud);
  }

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
    final CameraOffset cam = f.motion
        ? timeline.camera(time, h)
        : const CameraOffset(1, 0, 0, 0);
    canvas.save();
    canvas.translate(w / 2 + cam.dx, h / 2 + cam.dy);
    canvas.rotate(cam.rotation);
    canvas.scale(cam.scale);
    canvas.rotate(timeline.spin(time));
    canvas.translate(-w / 2, -h / 2 + timeline.rise(time));
    final List<_BeatPlaced> beats = _collectBeats(rig, size, f);
    for (int si = 0; si < rig.shots.length; si++) {
      final _ShotRig shot = rig.shots[si];
      if (time < shot.lifeStart || time > shot.lifeEnd) continue;
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
      if (text != null) {
        text.paintBlocks(canvas, time);
        text.paintGlyphs(canvas, time);
      }
      for (final HanabiOrnament o in shot.front) {
        o.paint(canvas, time);
      }
      canvas.restore();
    }
    canvas.restore();
  }

  _CreditsRig _creditsFor(Size size, HanabiFrame f, double lyricEnd) {
    final Object key = Object.hash(
      size,
      f.fontScale,
      f.baseStyle.fontFamily,
      f.settings.rigKey,
      f.motion,
      lyricEnd,
    );
    final _CreditsRig? existing = _credits;
    if (existing != null && key == _creditsKey) return existing;
    existing?.dispose();
    _creditsKey = key;
    return _credits = _CreditsRig(
      size: size,
      seed: '$_seed:credits',
      start: lyricEnd,
      title: title?.trim() ?? '',
      artist: artist?.trim() ?? '',
      album: album?.trim() ?? '',
      palette: resolveHanabiPalette(
        PaletteRole.kawaii,
        _paperTheme(f),
        f.settings.colorMode,
      ),
      fontScale: f.fontScale,
      baseStyle: f.baseStyle,
      motion: f.motion ? math.max(0, f.settings.textMotion) : 0,
      graphics: f.motion && !f.settings.textOnly,
      sparkAmount: f.settings.sparkAmount,
      launches: f.settings.launches,
    );
  }
}

// ─── 片尾卡 ─────────────────────────────────────────────────────────────

const double _bloomAt = 1.1;
const double _titleStart = 1.45;
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
    required String seed,
    required this.start,
    required String title,
    required this.artist,
    required this.album,
    required this.palette,
    required double fontScale,
    required this.baseStyle,
    required double motion,
    required bool graphics,
    required double sparkAmount,
    required bool launches,
  }) {
    final double w = size.width;
    final double h = size.height;
    final double unit = math.min(w, h);
    final List<String> chars = title.characters.toList();
    if (chars.isNotEmpty) {
      final double step = math.min(0.12, 2 / chars.length);
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
        spec: _titleSpec.copyWith(heroSize: 0.11 * fontScale),
        palette: palette,
        regionWidth: 0.72 * w,
        regionHeight: 0.26 * h,
        unit: unit,
        seed: '$seed:title',
        enterAt: start + _bloomAt - 0.1,
        exitAt: start + 1e6,
        exitDuration: 0.5,
        motion: motion,
        blockOpacity: 1,
        baseStyle: baseStyle,
      );
      _titleDone = _titleStart + math.min(2, 0.12 * chars.length);
    }
    if (graphics) {
      final List<(BurstSpec, double, double, double, double)> plan =
          <(BurstSpec, double, double, double, double)>[
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
            ),
            (
              burstPreset(BurstKind.senrin, const <int>[1, 2, 3]),
              0.2,
              0.3,
              1.65,
              0.8,
            ),
            (
              burstPreset(BurstKind.senrin, const <int>[2, 3, 0]),
              0.8,
              0.27,
              1.9,
              0.8,
            ),
            (
              burstPreset(BurstKind.willowRing, const <int>[3, 0, 1]),
              0.5,
              0.22,
              3.3,
              0.9,
            ),
          ];
      for (final (
            int k,
            (BurstSpec spec, double x, double y, double at, double scale),
          )
          in plan.indexed) {
        _bursts.add(
          planBurst(
            BurstEvent(
              x: x * w,
              y: y * h,
              at: start + at,
              spec: spec,
              seed: '$seed:b$k',
              scale: scale,
            ),
            palette,
            unit: unit,
            amount: math.max(0, sparkAmount),
          ),
        );
        if (launches) {
          _launches.add(
            LaunchEvent(
              fromX: x * w,
              fromY: h * 1.03,
              toX: x * w,
              toY: y * h,
              at: start + at - kLaunchDuration,
              duration: kLaunchDuration,
              color: palette.glow,
              seed: '$seed:l$k',
            ),
          );
        }
      }
    }
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

  TextPainter _detail(String text, double size, double spacing) =>
      _painters.putIfAbsent(
        '$text|$size',
        () => TextPainter(
          text: TextSpan(
            text: text,
            style: baseStyle.copyWith(
              fontSize: size,
              letterSpacing: size * spacing,
              color: rgbColor(palette.paper),
              fontWeight: FontWeight.w700,
            ),
          ),
          textDirection: TextDirection.ltr,
          textAlign: TextAlign.center,
        )..layout(),
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
      final TextPainter p = _detail(text, fontSize, spacing);
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
    canvas.restore();
  }

  void dispose() {
    _title?.dispose();
    _title = null;
    for (final TextPainter p in _painters.values) {
      p.dispose();
    }
    _painters.clear();
  }
}
