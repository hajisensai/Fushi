/// 浮名的世界背景（folia `fume/FumeBackground.ts`）：围着纸面散落的大圆环（带缺口）/ 方框 /
/// 十字，加纸面上方一格一颗的四角星火花。线条是两层渐变描边；火花带辉光、随「音频」缩放。
///
/// Fushi 没有实时频谱：火花的各频段读的是 [FumeBackgroundLevels]（由歌词节拍包络推出）。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/modes/fume/fume_math.dart';

enum FumeShapeKind { ring, square, cross, spark }

enum FumeAudioBand { bass, lowMid, mid, vocal, treble }

/// 一个背景物体。
class FumeBackgroundShape {
  const FumeBackgroundShape({
    required this.kind,
    required this.x,
    required this.y,
    required this.size,
    required this.rotation,
    required this.rotationSpeed,
    required this.strokeWidth,
    required this.opacity,
    required this.accent,
    required this.depth,
    this.band,
    this.ringGapStart,
    this.ringGapSize,
  });

  final FumeShapeKind kind;
  final double x;
  final double y;
  final double size;
  final double rotation;
  final double rotationSpeed;
  final double strokeWidth;
  final double opacity;

  /// true = 强调色，false = 次色。
  final bool accent;
  final double depth;
  final FumeAudioBand? band;
  final double? ringGapStart;
  final double? ringGapSize;
}

/// 背景场景（世界尺寸 + 物体，按深度排好）。
class FumeBackgroundScene {
  const FumeBackgroundScene(this.size, this.shapes);

  final Size size;
  final List<FumeBackgroundShape> shapes;
}

/// 各频段电平（0–255 量级，与 folia 的 audioBands 同尺度）。
typedef FumeBackgroundLevels = Map<FumeAudioBand, double>;

Offset _haloAnchor({
  required Rect paper,
  required Size world,
  required double size,
  required String seedKey,
}) {
  double cx(double v) => fumeClamp(v, 0, world.width);
  double cy(double v) => fumeClamp(v, 0, world.height);
  if (fumeSeeded('$seedKey:inside-chance') < 0.22) {
    return Offset(
      cx(
        fumeMix(
          paper.left + size * 0.12,
          paper.right - size * 0.12,
          fumeSeeded('$seedKey:inside-x'),
        ),
      ),
      cy(
        fumeMix(
          paper.top + size * 0.12,
          paper.bottom - size * 0.12,
          fumeSeeded('$seedKey:inside-y'),
        ),
      ),
    );
  }
  final int side = (fumeSeeded('$seedKey:side') * 4).floor() % 4;
  final double overflowX =
      size * fumeMix(0.16, 0.24, fumeSeeded('$seedKey:overflow-x'));
  final double overflowY =
      size * fumeMix(0.16, 0.24, fumeSeeded('$seedKey:overflow-y'));
  final double jitterX =
      size * fumeMix(-0.18, 0.18, fumeSeeded('$seedKey:span-jitter-x'));
  final double jitterY =
      size * fumeMix(-0.18, 0.18, fumeSeeded('$seedKey:span-jitter-y'));
  final double alongY = cy(
    fumeMix(
          paper.top - size * 0.12,
          paper.bottom + size * 0.12,
          fumeSeeded('$seedKey:y'),
        ) +
        jitterY,
  );
  final double alongX = cx(
    fumeMix(
          paper.left - size * 0.12,
          paper.right + size * 0.12,
          fumeSeeded('$seedKey:x'),
        ) +
        jitterX,
  );
  switch (side) {
    case 0:
      return Offset(cx(paper.left - overflowX), alongY);
    case 1:
      return Offset(cx(paper.right + overflowX), alongY);
    case 2:
      return Offset(alongX, cy(paper.top - overflowY));
    default:
      return Offset(alongX, cy(paper.bottom + overflowY));
  }
}

/// 造场景（folia `buildFumeBackgroundScene`）。
FumeBackgroundScene buildFumeBackgroundScene({
  required Size viewport,
  required Size world,
  Rect? paperBounds,
  required String seed,
}) {
  if (viewport.isEmpty || world.isEmpty) {
    return FumeBackgroundScene(
      Size(
        math.max(math.max(world.width, viewport.width), 1),
        math.max(math.max(world.height, viewport.height), 1),
      ),
      const <FumeBackgroundShape>[],
    );
  }
  final double ww = math.max(world.width, viewport.width * 1.2);
  final double wh = math.max(world.height, viewport.height * 1.2);
  final Size w = Size(ww, wh);
  final double baseUnit = fumeClamp(
    math.min(viewport.width, viewport.height) * 0.72,
    320,
    760,
  );
  final Rect raw =
      paperBounds ?? Rect.fromLTRB(ww * 0.24, wh * 0.18, ww * 0.76, wh * 0.82);
  final Rect paper = Rect.fromLTRB(
    fumeClamp(math.min(raw.left, raw.right), 0, ww),
    fumeClamp(math.min(raw.top, raw.bottom), 0, wh),
    fumeClamp(math.max(raw.left, raw.right), 0, ww),
    fumeClamp(math.max(raw.top, raw.bottom), 0, wh),
  );
  const List<FumeShapeKind> kinds = <FumeShapeKind>[
    FumeShapeKind.ring,
    FumeShapeKind.square,
    FumeShapeKind.cross,
  ];
  final int shapeCount = ww > wh ? 8 : 7;
  const List<FumeAudioBand> sparkBands = <FumeAudioBand>[
    FumeAudioBand.treble,
    FumeAudioBand.vocal,
    FumeAudioBand.mid,
    FumeAudioBand.treble,
    FumeAudioBand.lowMid,
  ];
  final int sparkCount = ww > wh ? 12 : 9;
  final double areaL = ww * 0.2;
  final double areaR = ww * 0.8;
  final double areaT = wh * 0.18;
  final double areaB = wh * 0.82;
  final int cols = math.sqrt(sparkCount * (ww / math.max(wh, 1))).ceil();
  final int rows = (sparkCount / cols).ceil();
  final double cellW = (areaR - areaL) / cols;
  final double cellH = (areaB - areaT) / rows;
  final String key = '$seed:${ww.round()}:${wh.round()}';

  final List<FumeBackgroundShape> shapes =
      <FumeBackgroundShape>[
        for (int i = 0; i < shapeCount; i++)
          () {
            final String s = '$key:$i';
            final FumeShapeKind kind = kinds[i % kinds.length];
            final double size =
                baseUnit * fumeMix(0.82, 1.36, fumeSeeded('$s:size'));
            final Offset a = _haloAnchor(
              paper: paper,
              world: w,
              size: size,
              seedKey: s,
            );
            return FumeBackgroundShape(
              kind: kind,
              x: a.dx,
              y: a.dy,
              size: size,
              rotation: fumeMix(
                -math.pi * 0.2,
                math.pi * 0.2,
                fumeSeeded('$s:rotation'),
              ),
              rotationSpeed: fumeMix(
                -0.045,
                0.045,
                fumeSeeded('$s:rotation-speed'),
              ),
              strokeWidth: fumeMix(0.25, 2.1, fumeSeeded('$s:stroke-width')),
              opacity: fumeMix(0.01, 0.16, fumeSeeded('$s:opacity')),
              accent: fumeSeeded('$s:color') > 0.5,
              depth: fumeSeeded('$s:depth'),
              ringGapStart: kind == FumeShapeKind.ring
                  ? fumeMix(-math.pi, math.pi, fumeSeeded('$s:gap-start'))
                  : null,
              ringGapSize: kind == FumeShapeKind.ring
                  ? fumeMix(
                      math.pi * 0.12,
                      math.pi * 0.24,
                      fumeSeeded('$s:gap-size'),
                    )
                  : null,
            );
          }(),
        for (int i = 0; i < sparkCount; i++)
          () {
            final String s = '$key:spark:$i';
            final int col = i % cols;
            final int row = i ~/ cols;
            final double jx =
                fumeMix(-0.32, 0.32, fumeSeeded('$s:jitter-x')) * cellW;
            final double jy =
                fumeMix(-0.32, 0.32, fumeSeeded('$s:jitter-y')) * cellH;
            return FumeBackgroundShape(
              kind: FumeShapeKind.spark,
              x: fumeClamp(areaL + (col + 0.5) * cellW + jx, areaL, areaR),
              y: fumeClamp(areaT + (row + 0.5) * cellH + jy, areaT, areaB),
              size: baseUnit * fumeMix(0.1, 0.24, fumeSeeded('$s:size')),
              rotation: fumeMix(-math.pi, math.pi, fumeSeeded('$s:rotation')),
              rotationSpeed: fumeMix(
                -0.18,
                0.18,
                fumeSeeded('$s:rotation-speed'),
              ),
              strokeWidth: fumeMix(0.75, 1.7, fumeSeeded('$s:stroke-width')),
              opacity: fumeMix(0.08, 0.22, fumeSeeded('$s:opacity')),
              accent: fumeSeeded('$s:color') > 0.5,
              depth: fumeSeeded('$s:depth'),
              band: sparkBands[i % sparkBands.length],
            );
          }(),
      ]..sort(
        (FumeBackgroundShape a, FumeBackgroundShape b) =>
            a.depth.compareTo(b.depth),
      );
  return FumeBackgroundScene(w, shapes);
}

/// 物体轮廓（以自身中心为原点）。
Path fumeShapePath(
  FumeShapeKind kind,
  double size, {
  double? gapStart,
  double? gapSize,
}) {
  final Path p = Path();
  final double h = size * 0.5;
  switch (kind) {
    case FumeShapeKind.ring:
      final double gs = gapStart ?? -math.pi * 0.18;
      final double gz = fumeClamp(
        gapSize ?? math.pi * 0.2,
        0.18,
        math.pi * 0.6,
      );
      p.addArc(
        Rect.fromCircle(center: Offset.zero, radius: h),
        gs + gz,
        math.pi * 2 - gz,
      );
    case FumeShapeKind.square:
      p.addRect(Rect.fromLTWH(-h, -h, size, size));
    case FumeShapeKind.cross:
      final double arm = size * 0.3;
      p
        ..moveTo(-arm, -h)
        ..lineTo(arm, -h)
        ..lineTo(arm, -arm)
        ..lineTo(h, -arm)
        ..lineTo(h, arm)
        ..lineTo(arm, arm)
        ..lineTo(arm, h)
        ..lineTo(-arm, h)
        ..lineTo(-arm, arm)
        ..lineTo(-h, arm)
        ..lineTo(-h, -arm)
        ..lineTo(-arm, -arm)
        ..close();
    case FumeShapeKind.spark:
      final double inner = size * 0.13;
      p
        ..moveTo(0, -h)
        ..lineTo(inner, -inner)
        ..lineTo(h, 0)
        ..lineTo(inner, inner)
        ..lineTo(0, h)
        ..lineTo(-inner, inner)
        ..lineTo(-h, 0)
        ..lineTo(-inner, -inner)
        ..close();
  }
  return p;
}

/// 画背景（调用方已把画布变换到世界坐标）。
class FumeBackgroundPainter {
  final Map<String, Path> _paths = <String, Path>{};
  final Map<String, ui.Shader> _gradients = <String, ui.Shader>{};

  void clear() {
    _paths.clear();
    _gradients.clear();
  }

  Path _pathOf(FumeBackgroundShape s, double size) {
    final String key =
        '${s.kind.index}|${size.toStringAsFixed(1)}|${s.ringGapStart}|${s.ringGapSize}';
    if (_paths.length > 512) _paths.clear();
    return _paths.putIfAbsent(
      key,
      () => fumeShapePath(
        s.kind,
        size,
        gapStart: s.ringGapStart,
        gapSize: s.ringGapSize,
      ),
    );
  }

  ui.Shader _gradient(
    double size,
    double opacity,
    Color secondary,
    Color accent,
  ) {
    final String key =
        '${size.toStringAsFixed(1)}|${opacity.toStringAsFixed(4)}|${secondary.toARGB32()}|${accent.toARGB32()}';
    if (_gradients.length > 256) _gradients.clear();
    return _gradients.putIfAbsent(
      key,
      () => ui.Gradient.linear(
        Offset(-size * 0.55, -size * 0.28),
        Offset(size * 0.55, size * 0.28),
        <Color>[
          secondary.withValues(alpha: opacity * 0.18),
          Color.lerp(
            secondary,
            accent,
            0.24,
          )!.withValues(alpha: opacity * 0.58),
          Color.lerp(
            secondary,
            accent,
            0.62,
          )!.withValues(alpha: opacity * 0.92),
          accent.withValues(alpha: opacity * 0.7),
        ],
        const <double>[0, 0.28, 0.54, 1],
      ),
    );
  }

  void paint(
    Canvas canvas, {
    required FumeBackgroundScene scene,
    required Color secondary,
    required Color accent,
    required double time,
    FumeBackgroundLevels? levels,
    Offset? parallaxCamera,
    Offset? parallaxOrigin,
    double parallaxStrength = 1,
    double objectOpacity = 1,
  }) {
    final double mult = fumeClamp(objectOpacity, 0, 2);
    for (final FumeBackgroundShape s in scene.shapes) {
      final double? band = s.band == null ? null : levels?[s.band];
      final double audio = band == null
          ? 0
          : fumeClamp((band - 10) / 190, 0, 1);
      final double audioScale = band == null ? 1 : fumeMix(0.95, 1.45, audio);
      final double audioBoost = band == null ? 1 : fumeMix(0.85, 1.55, audio);
      final Color color = s.accent ? accent : secondary;
      final double response = fumeMix(0.58, 1.16, s.depth);
      double px = 0;
      double py = 0;
      if (parallaxCamera != null && parallaxOrigin != null) {
        px =
            (parallaxCamera.dx - parallaxOrigin.dx) *
            (1 - response) *
            parallaxStrength;
        py =
            (parallaxCamera.dy - parallaxOrigin.dy) *
            (1 - response) *
            parallaxStrength;
      }
      final double size = s.size * audioScale;
      canvas
        ..save()
        ..translate(s.x + px, s.y + py)
        ..rotate(s.rotation + time * s.rotationSpeed);
      final Path path = _pathOf(s, size);
      final double opacity = fumeClamp(s.opacity * audioBoost * mult, 0, 0.42);
      if (s.kind == FumeShapeKind.spark) {
        final double glowAlpha = fumeClamp(
          s.opacity * audioBoost * 0.75 * mult,
          0,
          1,
        );
        if (glowAlpha > 0.003) {
          canvas.drawPath(
            path,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = s.strokeWidth
              ..color = color.withValues(alpha: glowAlpha)
              ..maskFilter = MaskFilter.blur(BlurStyle.normal, 5 * audioScale),
          );
        }
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = s.strokeWidth
            ..strokeJoin = StrokeJoin.miter
            ..color = color.withValues(alpha: opacity),
        );
      } else if (opacity > 0.0005) {
        // 两层渐变描边：细底线 + 主线。
        canvas
          ..drawPath(
            path,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeCap = StrokeCap.round
              ..strokeWidth = math.max(s.strokeWidth * 0.28, 0.14)
              ..shader = _gradient(size, opacity * 0.56, secondary, accent),
          )
          ..drawPath(
            path,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeCap = StrokeCap.round
              ..strokeWidth = math.max(s.strokeWidth * 0.92, 0.78)
              ..shader = _gradient(size, opacity, secondary, accent),
          );
      }
      canvas.restore();
    }
  }
}
