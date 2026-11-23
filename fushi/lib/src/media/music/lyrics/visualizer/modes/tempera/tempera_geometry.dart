/// 凝彩的网点图形语汇（folia `temperaHatch.ts` + `temperaCurves.ts`）：纯函数、按种子生成，
/// 多边形一律是扁平坐标表 `[x0, y0, x1, y1, ...]`。
///
/// 凸性是硬约束：[temperaHatchLines] 靠半平面裁剪，只有凸多边形（矩形、圆、椭圆、圆角矩形）
/// 能填斜线；心形 / 星形 / 波边 / 缎带是凹多边形，只能填色与描边。
library;

import 'dart:math' as math;

import 'package:fushi/src/media/music/lyrics/visualizer/modes/tempera/tempera_random.dart';

const double _tau = math.pi * 2;

/// 斜线填充参数。
class TemperaHatchSpec {
  const TemperaHatchSpec(this.angle, this.spacing, this.width);

  final double angle;
  final double spacing;
  final double width;

  TemperaHatchSpec copyWith({double? angle, double? spacing}) =>
      TemperaHatchSpec(angle ?? this.angle, spacing ?? this.spacing, width);
}

/// 一条线段。
class TemperaLine {
  const TemperaLine(this.x1, this.y1, this.x2, this.y2);

  final double x1;
  final double y1;
  final double x2;
  final double y2;
}

/// 一个记号（叉 / 方点）。
class TemperaMark {
  const TemperaMark(this.x, this.y, this.size, this.rotation);

  final double x;
  final double y;
  final double size;
  final double rotation;
}

/// 一个圆。
class TemperaDisc {
  const TemperaDisc(this.x, this.y, this.radius);

  final double x;
  final double y;
  final double radius;
}

TemperaHatchSpec temperaHatchSpec(int seed, int salt, [double scale = 1]) {
  final int angleIndex = (temperaHash01(seed, 1, salt) * 4).floor();
  const List<double> angles = <double>[
    -math.pi / 4,
    math.pi / 4,
    -math.pi / 3,
    math.pi / 6,
  ];
  final int density = (temperaHash01(seed, 2, salt) * 3).floor();
  const List<double> spacings = <double>[9, 13, 18];
  final double spacing = spacings[density.clamp(0, 2)] * scale;
  final double width = math.max(
    0.8,
    spacing * (0.16 + temperaHash01(seed, 3, salt) * 0.14),
  );
  return TemperaHatchSpec(angles[angleIndex.clamp(0, 3)], spacing, width);
}

List<double> rectPolygon(double x, double y, double w, double h) => <double>[
  x,
  y,
  x + w,
  y,
  x + w,
  y + h,
  x,
  y + h,
];

List<double> circlePolygon(
  double cx,
  double cy,
  double radius, [
  int segments = 28,
]) {
  final int count = math.max(6, segments);
  return <double>[
    for (int i = 0; i < count; i++) ...<double>[
      cx + math.cos(i / count * _tau) * radius,
      cy + math.sin(i / count * _tau) * radius,
    ],
  ];
}

List<double> diamondPolygon(double cx, double cy, double rx, double ry) =>
    <double>[cx, cy - ry, cx + rx, cy, cx, cy + ry, cx - rx, cy];

TemperaLine? _clipToConvex(
  List<double> polygon,
  double ax,
  double ay,
  double dx,
  double dy,
  double span,
) {
  final int count = polygon.length ~/ 2;
  double cx = 0;
  double cy = 0;
  for (int i = 0; i < count; i++) {
    cx += polygon[i * 2];
    cy += polygon[i * 2 + 1];
  }
  cx /= count;
  cy /= count;
  double tMin = -span;
  double tMax = span;
  for (int i = 0; i < count; i++) {
    final double x0 = polygon[i * 2];
    final double y0 = polygon[i * 2 + 1];
    final double x1 = polygon[((i + 1) % count) * 2];
    final double y1 = polygon[((i + 1) % count) * 2 + 1];
    double nx = y1 - y0;
    double ny = -(x1 - x0);
    if (nx * (cx - x0) + ny * (cy - y0) > 0) {
      nx = -nx;
      ny = -ny;
    }
    final double den = nx * dx + ny * dy;
    final double num = nx * (ax - x0) + ny * (ay - y0);
    if (den.abs() < 1e-9) {
      if (num > 0) return null;
      continue;
    }
    final double t = -num / den;
    if (den > 0) {
      tMax = math.min(tMax, t);
    } else {
      tMin = math.max(tMin, t);
    }
    if (tMin > tMax) return null;
  }
  if (tMax - tMin < 0.5) return null;
  return TemperaLine(
    ax + dx * tMin,
    ay + dy * tMin,
    ax + dx * tMax,
    ay + dy * tMax,
  );
}

/// 用平行线填满一个凸多边形。
List<TemperaLine> temperaHatchLines(
  List<double> polygon,
  TemperaHatchSpec spec,
) {
  if (polygon.length < 6 || spec.spacing <= 0) return const <TemperaLine>[];
  double minX = double.infinity;
  double maxX = double.negativeInfinity;
  double minY = double.infinity;
  double maxY = double.negativeInfinity;
  for (int i = 0; i < polygon.length; i += 2) {
    minX = math.min(minX, polygon[i]);
    maxX = math.max(maxX, polygon[i]);
    minY = math.min(minY, polygon[i + 1]);
    maxY = math.max(maxY, polygon[i + 1]);
  }
  final double centerX = (minX + maxX) / 2;
  final double centerY = (minY + maxY) / 2;
  final double diagonal = math.sqrt(
    (maxX - minX) * (maxX - minX) + (maxY - minY) * (maxY - minY),
  );
  if (diagonal <= 0) return const <TemperaLine>[];
  final double dx = math.cos(spec.angle);
  final double dy = math.sin(spec.angle);
  final double px = -dy;
  final double py = dx;
  final int steps = math.min(160, (diagonal / (spec.spacing * 2)).ceil() + 2);
  final List<TemperaLine> lines = <TemperaLine>[];
  for (int step = -steps; step <= steps; step++) {
    final double offset = step * spec.spacing;
    final TemperaLine? clipped = _clipToConvex(
      polygon,
      centerX + px * offset,
      centerY + py * offset,
      dx,
      dy,
      diagonal,
    );
    if (clipped != null) lines.add(clipped);
  }
  return lines;
}

/// 抖动的螺旋折线：手画涂鸦。
List<double> temperaScribblePath(
  int seed,
  int salt,
  double cx,
  double cy,
  double radius, [
  double turns = 2,
]) {
  const int perTurn = 13;
  final double t = math.max(1, turns);
  final int total = math.max(perTurn, (perTurn * t).round());
  final List<double> points = <double>[];
  for (int i = 0; i <= total; i++) {
    final double progress = i / total;
    final double angle = progress * _tau * t;
    final double jr = (temperaHash01(seed, i, salt) - 0.5) * radius * 0.26;
    final double ja = (temperaHash01(seed, i, salt + 7) - 0.5) * 0.22;
    final double r = radius * (0.52 + 0.48 * progress) + jr;
    points
      ..add(cx + math.cos(angle + ja) * r)
      ..add(cy + math.sin(angle + ja) * r * 0.82);
  }
  return points;
}

/// 起伏的横边。
List<double> temperaWavyPath(
  int seed,
  int salt,
  double x0,
  double x1,
  double y,
  double amplitude, [
  int steps = 24,
]) {
  final int n = math.max(2, steps);
  final double phase = temperaHash01(seed, 0, salt) * _tau;
  return <double>[
    for (int i = 0; i <= n; i++) ...<double>[
      x0 + (x1 - x0) * (i / n),
      y +
          math.sin(i / n * _tau * 1.5 + phase) * amplitude +
          (temperaHash01(seed, i, salt) - 0.5) * amplitude * 0.5,
    ],
  ];
}

List<TemperaMark> _markRow(
  int seed,
  int salt,
  double x,
  double y,
  int count,
  double spacing,
  double size,
  double angle,
) {
  final double dx = math.cos(angle);
  final double dy = math.sin(angle);
  return <TemperaMark>[
    for (int i = 0; i < math.max(0, count); i++)
      TemperaMark(
        x +
            dx *
                (i * spacing +
                    (temperaHash01(seed, i, salt) - 0.5) * spacing * 0.16),
        y +
            dy *
                (i * spacing +
                    (temperaHash01(seed, i, salt) - 0.5) * spacing * 0.16),
        size * (0.82 + temperaHash01(seed, i, salt + 3) * 0.36),
        (temperaHash01(seed, i, salt + 11) - 0.5) * 0.3,
      ),
  ];
}

List<TemperaMark> temperaCrossRow(
  int seed,
  int salt,
  double x,
  double y,
  int count,
  double spacing, [
  double size = 9,
  double angle = 0,
]) => _markRow(seed, salt, x, y, count, spacing, size, angle);

List<TemperaMark> temperaDotRow(
  int seed,
  int salt,
  double x,
  double y,
  int count,
  double spacing, [
  double size = 4,
  double angle = math.pi / 2,
]) => _markRow(seed, salt, x, y, count, spacing, size, angle);

/// 错行的点阵（纸面网点）。
List<TemperaMark> temperaDotGrid(
  double width,
  double height,
  double spacing, [
  double size = 1.6,
]) {
  if (spacing <= 0 || width <= 0 || height <= 0) return const <TemperaMark>[];
  final int columns = math.min(200, (width / spacing).ceil() + 1);
  final int rows = math.min(200, (height / spacing).ceil() + 1);
  return <TemperaMark>[
    for (int r = 0; r < rows; r++)
      for (int c = 0; c < columns; c++)
        TemperaMark(
          c * spacing + (r.isEven ? 0 : spacing / 2),
          r * spacing,
          size,
          0,
        ),
  ];
}

/// 1–3 条伸出画外的浅斜贯穿线。
List<TemperaLine> temperaCrossingLines(
  int seed,
  int salt,
  double width,
  double height,
  int count,
) {
  final int total = math.min(3, math.max(0, count));
  return <TemperaLine>[
    for (int i = 0; i < total; i++)
      () {
        final double anchorY =
            height * (0.18 + temperaHash01(seed, i, salt) * 0.64);
        final double sign = temperaHash01(seed, i, salt + 5) > 0.5 ? 1 : -1;
        final double angle =
            sign * (0.07 + temperaHash01(seed, i, salt + 9) * 0.11);
        final double reach = width * 0.9;
        return TemperaLine(
          -width * 0.3,
          anchorY - math.tan(angle) * reach,
          width * 1.3,
          anchorY + math.tan(angle) * reach,
        );
      }(),
  ];
}

// ---------------------------------------------------------------------------
// 曲线（folia temperaCurves.ts）
// ---------------------------------------------------------------------------

/// 凸。
List<double> ellipsePolygon(
  double cx,
  double cy,
  double rx,
  double ry, [
  int segments = 32,
]) {
  final int count = math.max(8, segments);
  return <double>[
    for (int i = 0; i < count; i++) ...<double>[
      cx + math.cos(i / count * _tau) * rx,
      cy + math.sin(i / count * _tau) * ry,
    ],
  ];
}

/// 凸。贴纸板。
List<double> roundedRectPolygon(
  double x,
  double y,
  double width,
  double height,
  double radius, [
  int cornerSegments = 6,
]) {
  final double limit = math.max(
    0,
    math.min(radius, math.min(width, height) / 2),
  );
  final int steps = math.max(1, cornerSegments);
  final List<(double, double, double)> corners = <(double, double, double)>[
    (x + width - limit, y + limit, -math.pi / 2),
    (x + width - limit, y + height - limit, 0),
    (x + limit, y + height - limit, math.pi / 2),
    (x + limit, y + limit, math.pi),
  ];
  return <double>[
    for (final (double ccx, double ccy, double start) in corners)
      for (int s = 0; s <= steps; s++) ...<double>[
        ccx + math.cos(start + s / steps * (math.pi / 2)) * limit,
        ccy + math.sin(start + s / steps * (math.pi / 2)) * limit,
      ],
  ];
}

List<double> rotatePolygon(
  List<double> polygon,
  double cx,
  double cy,
  double angle,
) {
  final double c = math.cos(angle);
  final double s = math.sin(angle);
  return <double>[
    for (int i = 0; i < polygon.length; i += 2) ...<double>[
      cx + (polygon[i] - cx) * c - (polygon[i + 1] - cy) * s,
      cy + (polygon[i] - cx) * s + (polygon[i + 1] - cy) * c,
    ],
  ];
}

/// 凹。带花瓣起伏的外轮廓（云朵 / 蕾丝 / 玫瑰窗）。
List<double> lobedPolygon(
  double cx,
  double cy,
  double rx,
  double ry,
  int lobes,
  double amplitude, [
  int segments = 96,
]) {
  final int count = math.max(24, segments);
  final int petals = math.max(1, lobes);
  final double swell = math.max(0, amplitude);
  return <double>[
    for (int i = 0; i < count; i++)
      ...() {
        final double a = i / count * _tau;
        final double k = (1 + math.cos(a * petals) * swell) / (1 + swell);
        return <double>[cx + math.cos(a) * rx * k, cy + math.sin(a) * ry * k];
      }(),
  ];
}

/// 凹。一边平、一边挂一排半圆的蕾丝波边。
List<double> scallopBandPolygon(
  double x0,
  double x1,
  double flatY,
  double baseY,
  int bumps, [
  int segmentsPerBump = 10,
]) {
  final int count = math.max(1, bumps);
  final int steps = math.max(3, segmentsPerBump);
  final double span = (x1 - x0) / count;
  final double radius = span.abs() / 2;
  final double direction = baseY >= flatY ? 1 : -1;
  final List<double> points = <double>[x0, flatY, x1, flatY];
  for (int bump = count - 1; bump >= 0; bump--) {
    final double cx = x0 + span * (bump + 0.5);
    for (int s = 0; s <= steps; s++) {
      final double a = s / steps * math.pi;
      points
        ..add(cx + math.cos(a) * (span / 2))
        ..add(baseY + direction * math.sin(a) * radius);
    }
  }
  return points;
}

/// 凹。参数心形，归一到 rx/ry 框里。
List<double> heartPolygon(
  double cx,
  double cy,
  double rx,
  double ry, [
  int segments = 64,
]) {
  final int count = math.max(16, segments);
  final List<double> raw = <double>[];
  double minX = double.infinity;
  double maxX = double.negativeInfinity;
  double minY = double.infinity;
  double maxY = double.negativeInfinity;
  for (int i = 0; i < count; i++) {
    final double t = i / count * _tau;
    final double x = math.pow(math.sin(t), 3).toDouble() * 16;
    final double y =
        -(13 * math.cos(t) -
            5 * math.cos(2 * t) -
            2 * math.cos(3 * t) -
            math.cos(4 * t));
    raw
      ..add(x)
      ..add(y);
    minX = math.min(minX, x);
    maxX = math.max(maxX, x);
    minY = math.min(minY, y);
    maxY = math.max(maxY, y);
  }
  final double hw = math.max(1e-6, (maxX - minX) / 2);
  final double hh = math.max(1e-6, (maxY - minY) / 2);
  final double mx = (minX + maxX) / 2;
  final double my = (minY + maxY) / 2;
  return <double>[
    for (int i = 0; i < raw.length; i += 2) ...<double>[
      cx + (raw[i] - mx) / hw * rx,
      cy + (raw[i + 1] - my) / hh * ry,
    ],
  ];
}

/// 凹。环的一段。
List<double> annularSectorPolygon(
  double cx,
  double cy,
  double inner,
  double outer,
  double start,
  double end, [
  int segments = 10,
]) {
  final int steps = math.max(2, segments);
  return <double>[
    for (int s = 0; s <= steps; s++) ...<double>[
      cx + math.cos(start + (end - start) * s / steps) * outer,
      cy + math.sin(start + (end - start) * s / steps) * outer,
    ],
    for (int s = steps; s >= 0; s--) ...<double>[
      cx + math.cos(start + (end - start) * s / steps) * inner,
      cy + math.sin(start + (end - start) * s / steps) * inner,
    ],
  ];
}

/// 凹。四芒是 VN 的 kirakira，更多芒读作星。
List<double> starPolygon(
  double cx,
  double cy,
  double outer,
  double inner,
  int points, [
  double rotation = 0,
]) {
  final int tips = math.max(3, points);
  return <double>[
    for (int i = 0; i < tips * 2; i++) ...<double>[
      cx +
          math.cos(rotation - math.pi / 2 + i / (tips * 2) * _tau) *
              (i.isEven ? outer : inner),
      cy +
          math.sin(rotation - math.pi / 2 + i / (tips * 2) * _tau) *
              (i.isEven ? outer : inner),
    ],
  ];
}

/// 凹。中线沿半个正弦下垂的缎带。
List<double> arcRibbonPolygon(
  double x0,
  double x1,
  double y,
  double thickness,
  double sag, [
  int steps = 28,
]) {
  final int count = math.max(4, steps);
  final double half = thickness / 2;
  final List<double> top = <double>[];
  final List<double> bottom = <double>[];
  for (int i = 0; i <= count; i++) {
    final double p = i / count;
    final double x = x0 + (x1 - x0) * p;
    final double centre = y + math.sin(p * math.pi) * sag;
    top
      ..add(x)
      ..add(centre - half);
    bottom
      ..add(x)
      ..add(centre + half);
  }
  final List<double> points = <double>[...top];
  for (int i = bottom.length - 2; i >= 0; i -= 2) {
    points
      ..add(bottom[i])
      ..add(bottom[i + 1]);
  }
  return points;
}

/// 抖动格点上的一片圆。
List<TemperaDisc> temperaDiscField(
  int seed,
  int salt,
  double width,
  double height,
  int count,
  double radius,
) {
  final int total = math.max(0, count);
  if (total == 0 || width <= 0 || height <= 0) return const <TemperaDisc>[];
  final int columns = math.max(1, math.sqrt(total * (width / height)).round());
  final int rows = math.max(1, (total / columns).ceil());
  final double cw = width / columns;
  final double ch = height / rows;
  return <TemperaDisc>[
    for (int i = 0; i < total; i++)
      TemperaDisc(
        cw * (i % columns + 0.15 + temperaHash01(seed, i, salt) * 0.7),
        ch * (i ~/ columns + 0.15 + temperaHash01(seed, i, salt + 3) * 0.7),
        radius * (0.55 + temperaHash01(seed, i, salt + 7) * 0.75),
      ),
  ];
}
