/// 背景「通用」（移植 folia `backgrounds/common/`：`entry.tsx`、`FluidBackground.tsx`、
/// `GeometricBackground.tsx/.css`）：主题底色（可叠封面模糊色彩层）+ 随频段缩放的几何图形与上升粒子
/// + 暗角。图形按 seed 布局，暂停时所有循环停在原处。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/backgrounds/background_scene.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart'
    show LyricVisualizerRandom;
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_frame.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 落库键（冻结，沿用 folia 字段名）。
abstract final class CommonBackgroundKeys {
  static const String useCoverColorBg = 'useCoverColorBg';
  static const String opacity = 'opacity';
  static const String disableGeometricBackground = 'disableGeometricBackground';
  static const String disableVignette = 'disableVignette';
}

String _percent(double v) => '${(v * 100).round()}%';

final List<LyricVisualizerTuningSpec> commonBackgroundTunings =
    <LyricVisualizerTuningSpec>[
      LyricVisualizerToggleSpec(
        key: CommonBackgroundKeys.useCoverColorBg,
        label: () => t.music_visualizer_background_common_cover_color,
        initial: false,
      ),
      LyricVisualizerSliderSpec(
        key: CommonBackgroundKeys.opacity,
        label: () => t.music_visualizer_background_common_opacity,
        min: 0,
        max: 1,
        initial: 0.75,
        divisions: 20,
        format: _percent,
        visibleWhen: (LyricVisualizerTuning v) =>
            v.flag(CommonBackgroundKeys.useCoverColorBg, false),
      ),
      LyricVisualizerToggleSpec(
        key: CommonBackgroundKeys.disableGeometricBackground,
        label: () => t.music_visualizer_background_common_hide_shapes,
        initial: false,
      ),
      LyricVisualizerToggleSpec(
        key: CommonBackgroundKeys.disableVignette,
        label: () => t.music_visualizer_background_common_disable_vignette,
        initial: false,
      ),
    ];

/// 注册项。
final LyricVisualizerBackgroundEntry commonBackgroundEntry =
    LyricVisualizerBackgroundEntry(
      id: 'common',
      label: () => t.music_visualizer_background_common,
      icon: FushiIcons.formatShapes,
      tunings: commonBackgroundTunings,
      builder: (LyricVisualizerContext c, LyricVisualizerTuning tu) =>
          LyricVisualizerBackgroundView(
            context: c,
            tuning: tu,
            create: CommonBackgroundScene.new,
          ),
    );

// ---------------------------------------------------------------------------
// 布局（纯函数，可单测）
// ---------------------------------------------------------------------------

/// 图形种类（folia `ShapeType`）。
enum CommonShapeType { circle, square, triangle, cross }

/// 一个几何图形（folia `BackgroundShape`；尺寸是逻辑像素，位置是百分比）。
@immutable
class CommonShape {
  const CommonShape({
    required this.type,
    required this.x,
    required this.y,
    required this.size,
    required this.duration,
    required this.delay,
    required this.opacity,
    required this.reverse,
    required this.filled,
    required this.rotation,
  });

  final CommonShapeType type;
  final double x;
  final double y;
  final double size;
  final double duration;
  final double delay;
  final double opacity;
  final bool reverse;
  final bool filled;

  /// 初始旋转（度）。
  final double rotation;
}

/// 上升粒子（folia `BackgroundParticle`）。
@immutable
class CommonParticle {
  const CommonParticle({
    required this.size,
    required this.left,
    required this.top,
    required this.opacity,
    required this.duration,
    required this.delay,
  });

  final double size;
  final double left;
  final double top;
  final double opacity;
  final double duration;
  final double delay;
}

/// 按 seed 布 15 个图形（分布与 folia 相同；folia 的「主题图标槽」Fushi 主题没有图标，按图形画）。
List<CommonShape> commonBackgroundShapes(int seed) {
  final LyricVisualizerRandom rnd = LyricVisualizerRandom(seed);
  int iconSlots = 0;
  return <CommonShape>[
    for (int i = 0; i < 15; i++)
      () {
        final bool slot = iconSlots < 6 && rnd.next() > 0.7;
        if (slot) {
          iconSlots++;
          rnd.next();
        }
        final CommonShapeType type =
            CommonShapeType.values[(rnd.next() * 4).floor().clamp(0, 3)];
        return CommonShape(
          type: type,
          x: rnd.next() * 100,
          y: rnd.next() * 100,
          size: 40 + rnd.next() * 100,
          duration: slot ? 20 + rnd.next() * 20 : 30 + rnd.next() * 30,
          delay: rnd.next() * 5,
          opacity: 0.11 + rnd.next() * 0.08,
          reverse: rnd.next() > 0.5,
          filled: rnd.next() < 0.3,
          rotation: rnd.next() * 360,
        );
      }(),
  ];
}

/// 按 seed 布 20 个粒子。
List<CommonParticle> commonBackgroundParticles(int seed) {
  final LyricVisualizerRandom rnd = LyricVisualizerRandom(seed ^ 0x5f3759df);
  return <CommonParticle>[
    for (int i = 0; i < 20; i++)
      CommonParticle(
        size: rnd.next() * 4 + 1,
        left: rnd.next() * 100,
        top: rnd.next() * 100,
        opacity: rnd.next() * 0.3,
        duration: 15 + rnd.next() * 20,
        delay: rnd.next() * 10,
      ),
  ];
}

/// CSS 循环的进度（0–1）：延时内停在首帧（`animation-fill-mode: backwards`）。
double commonLoopPhase(double time, double duration, double delay) {
  if (time <= delay) return 0;
  final double p = (time - delay) / duration;
  return p - p.floorToDouble();
}

/// `geometric-drift` 关键帧：平移（px）与旋转（度）。
({Offset offset, double rotation}) commonShapeDrift(
  CommonShape s,
  double phase,
) {
  final double dir = s.reverse ? -1 : 1;
  final Offset a = Offset(-15 * dir, 30 * dir);
  final Offset b = Offset(15 * dir, -30 * dir);
  final Offset o = phase < 0.5
      ? Offset.lerp(a, b, phase * 2)!
      : Offset.lerp(b, a, (phase - 0.5) * 2)!;
  return (offset: o, rotation: s.rotation + 360 * phase);
}

/// framer `useTransform(spring, [10, 200], [0.95, 1.45])`（默认夹紧）。
double commonBandScale(double byteValue) {
  final double t = ((byteValue - 10) / 190).clamp(0.0, 1.0);
  return 0.95 + 0.5 * t;
}

// ---------------------------------------------------------------------------
// 场景
// ---------------------------------------------------------------------------

/// 频段：0 低 / 1 中低 / 2 中 / 3 人声 / 4 高 / 5 整体。
const int _kBands = 6;

class CommonBackgroundScene extends LyricVisualizerBackgroundScene {
  CommonBackgroundScene() {
    _cover.addListener(_onCover);
  }

  final LyricBgImageSource _cover = LyricBgImageSource();
  final List<LyricBgSpring> _bands = <LyricBgSpring>[
    for (int i = 0; i < _kBands; i++) LyricBgSpring(),
  ];
  late LyricVisualizerContext _c;
  late LyricVisualizerTuning _tu;
  int? _seed;
  List<CommonShape> _shapes = const <CommonShape>[];
  List<CommonParticle> _particles = const <CommonParticle>[];
  late LyricBgColorBlend _primary;
  late LyricBgColorBlend _secondary;
  bool _blendsReady = false;
  double _time = 0;
  ui.Image? _blurred;
  ui.Image? _blurSource;
  Size _blurSize = Size.zero;

  bool get _useCover => _tu.flag(CommonBackgroundKeys.useCoverColorBg, false);

  void _onCover() {
    _blurred?.dispose();
    _blurred = null;
    _blurSource = null;
    notifyListeners();
  }

  @override
  void configure(
    LyricVisualizerContext context,
    LyricVisualizerTuning tuning,
    double devicePixelRatio,
  ) {
    _c = context;
    _tu = tuning;
    if (_seed != context.seed) {
      _seed = context.seed;
      _shapes = commonBackgroundShapes(context.seed);
      _particles = commonBackgroundParticles(context.seed);
    }
    if (!_blendsReady) {
      _primary = LyricBgColorBlend(context.palette.primary);
      _secondary = LyricBgColorBlend(context.palette.secondary);
      _blendsReady = true;
    }
    _primary.target(context.palette.primary, immediate: !context.motion);
    _secondary.target(context.palette.secondary, immediate: !context.motion);
    _cover.select(coverPath: _useCover ? context.coverPath : null);
  }

  @override
  void advance(LyricVisualizerTick tick) {
    _primary.advance(tick.dt);
    _secondary.advance(tick.dt);
    if (!_c.motion) return;
    final bool playing = _c.playing;
    if (playing) _time += tick.dt;
    final LyricVisualizerAudioFrame f = _c.audioFrameAt(tick.timeMs);
    // folia 的分析器暂停时读数为 0。
    final List<double> targets = playing
        ? <double>[f.low, f.mid, f.mid, f.vocal, f.high, f.power]
        : List<double>.filled(_kBands, 0);
    for (int i = 0; i < _kBands; i++) {
      _bands[i].step(lyricBgByte(targets[i]), tick.dt);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final LyricVisualizerPalette p = _c.palette;
    final Rect all = Offset.zero & size;
    if (_useCover) _paintCoverLayer(canvas, size, p);
    canvas.drawRect(
      all,
      Paint()
        ..color = p.background.withValues(
          alpha: _useCover
              ? _tu.number(CommonBackgroundKeys.opacity, 0.75).clamp(0.0, 1.0)
              : 1,
        ),
    );
    // folia staticMode（减弱动态效果）整层几何不画。
    if (!_c.motion) return;
    if (!_tu.flag(CommonBackgroundKeys.disableGeometricBackground, false)) {
      _paintShapes(canvas, size, p);
      _paintParticles(canvas, size, p);
    }
    if (!_tu.flag(CommonBackgroundKeys.disableVignette, false)) {
      final double far = size.longestSide == 0
          ? 1
          : math.sqrt(size.width * size.width + size.height * size.height) / 2;
      canvas.drawRect(
        all,
        Paint()
          ..shader = ui.Gradient.radial(
            all.center,
            far,
            const <Color>[
              Color(0x00000000),
              Color(0x00000000),
              Color(0x99000000),
            ],
            const <double>[0, 0.4, 1],
          ),
      );
    }
  }

  /// folia `FluidBackground`：封面 cover 铺满、放大 1.5、模糊 40px（烘焙到 320 宽的小图），
  /// 再以 overlay 叠 40% 的「主色 → 透明 → 辅色」对角渐变。没封面时是 80% 底色 + 同一渐变。
  void _paintCoverLayer(Canvas canvas, Size size, LyricVisualizerPalette p) {
    final Rect all = Offset.zero & size;
    final ui.Image? cover = _cover.image;
    if (cover != null) {
      final ui.Image? baked = _bakeBlur(cover, size);
      if (baked != null) {
        canvas.drawImageRect(
          baked,
          Rect.fromLTWH(0, 0, baked.width.toDouble(), baked.height.toDouble()),
          all,
          Paint()..filterQuality = FilterQuality.medium,
        );
      }
    } else {
      canvas.drawRect(
        all,
        Paint()..color = p.background.withValues(alpha: 0.8),
      );
    }
    final Color a = _primary.value;
    final Color b = _secondary.value;
    final double diagonal = math.sqrt(
      size.width * size.width + size.height * size.height,
    );
    final double half = size.width * size.height / diagonal;
    final double dx = size.height / diagonal * half;
    final double dy = size.width / diagonal * half;
    final Offset c = all.center;
    canvas.drawRect(
      all,
      Paint()
        ..blendMode = BlendMode.overlay
        ..color = const Color.fromRGBO(0, 0, 0, 0.4)
        ..shader = ui.Gradient.linear(
          c - Offset(dx, dy),
          c + Offset(dx, dy),
          <Color>[a, a.withValues(alpha: 0), b.withValues(alpha: 0), b],
          const <double>[0, 0.5, 0.5, 1],
        ),
    );
  }

  ui.Image? _bakeBlur(ui.Image cover, Size size) {
    if (_blurred != null &&
        identical(_blurSource, cover) &&
        _blurSize == size) {
      return _blurred;
    }
    _blurred?.dispose();
    const int w = 320;
    final int h = math.max(1, (w * size.height / size.width).round());
    final ui.PictureRecorder rec = ui.PictureRecorder();
    final Canvas c = Canvas(rec);
    final Size src = Size(cover.width.toDouble(), cover.height.toDouble());
    final double scale = math.max(w / src.width, h / src.height) * 1.5;
    final double dw = src.width * scale;
    final double dh = src.height * scale;
    final double sigma = 40 * 1.5 * w / size.width / 2;
    c.drawImageRect(
      cover,
      Offset.zero & src,
      Rect.fromLTWH((w - dw) / 2, (h - dh) / 2, dw, dh),
      Paint()
        ..filterQuality = FilterQuality.medium
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: sigma,
          sigmaY: sigma,
          tileMode: TileMode.clamp,
        ),
    );
    final ui.Picture pic = rec.endRecording();
    _blurred = pic.toImageSync(w, h);
    pic.dispose();
    _blurSource = cover;
    _blurSize = size;
    return _blurred;
  }

  double _bandFor(CommonShapeType type) => commonBandScale(
    _bands[switch (type) {
          CommonShapeType.circle => 0,
          CommonShapeType.square => 1,
          CommonShapeType.triangle => 2,
          CommonShapeType.cross => 4,
        }]
        .value,
  );

  void _paintShapes(Canvas canvas, Size size, LyricVisualizerPalette p) {
    final Color color = _secondary.value;
    for (final CommonShape s in _shapes) {
      final double phase = commonLoopPhase(_time, s.duration, s.delay);
      final ({Offset offset, double rotation}) d = commonShapeDrift(s, phase);
      final Offset center =
          Offset(size.width * s.x / 100, size.height * s.y / 100) +
          Offset(s.size / 2, s.size / 2) +
          d.offset;
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(d.rotation * math.pi / 180);
      final double k = _bandFor(s.type);
      canvas.scale(k);
      final Rect box = Rect.fromCenter(
        center: Offset.zero,
        width: s.size,
        height: s.size,
      );
      final bool stroke =
          (s.type == CommonShapeType.circle ||
              s.type == CommonShapeType.square) &&
          !s.filled;
      final Paint paint = Paint()
        ..color = color.withValues(alpha: color.a * s.opacity)
        ..style = stroke ? PaintingStyle.stroke : PaintingStyle.fill
        ..strokeWidth = 1 / k;
      switch (s.type) {
        case CommonShapeType.circle:
          canvas.drawOval(stroke ? box.deflate(0.5 / k) : box, paint);
        case CommonShapeType.square:
          canvas.drawRect(stroke ? box.deflate(0.5 / k) : box, paint);
        case CommonShapeType.triangle:
          canvas.drawPath(_polygon(box, _kTriangle), paint);
        case CommonShapeType.cross:
          canvas.drawPath(_polygon(box, _kCross), paint);
      }
      canvas.restore();
    }
  }

  void _paintParticles(Canvas canvas, Size size, LyricVisualizerPalette p) {
    final Paint paint = Paint();
    for (final CommonParticle q in _particles) {
      final double phase = commonLoopPhase(_time, q.duration, q.delay);
      final double alpha = _time <= q.delay
          ? 0
          : (phase < 0.5 ? phase * 2 : (1 - phase) * 2) * q.opacity;
      if (alpha <= 0.002) continue;
      paint.color = p.accent.withValues(alpha: p.accent.a * alpha);
      final Offset c = Offset(
        size.width * q.left / 100 + q.size / 2,
        size.height * q.top / 100 + q.size / 2 - 100 * phase,
      );
      canvas.drawCircle(c, q.size / 2, paint);
    }
  }

  @override
  void dispose() {
    _cover.removeListener(_onCover);
    _cover.dispose();
    _blurred?.dispose();
    super.dispose();
  }
}

/// CSS clip-path 多边形（百分比）。
const List<Offset> _kTriangle = <Offset>[
  Offset(50, 0),
  Offset(0, 100),
  Offset(100, 100),
];
const List<Offset> _kCross = <Offset>[
  Offset(20, 0),
  Offset(0, 20),
  Offset(30, 50),
  Offset(0, 80),
  Offset(20, 100),
  Offset(50, 70),
  Offset(80, 100),
  Offset(100, 80),
  Offset(70, 50),
  Offset(100, 20),
  Offset(80, 0),
  Offset(50, 30),
];

Path _polygon(Rect box, List<Offset> pts) => Path()
  ..addPolygon(<Offset>[
    for (final Offset o in pts)
      Offset(
        box.left + box.width * o.dx / 100,
        box.top + box.height * o.dy / 100,
      ),
  ], true);
