/// 光学线稿：一组折线（高度单位坐标），按进度描出来，节点上有闪点（folia `lumiere/lineart/`
/// 的 lineArt.ts 数据部分 + recipes.ts + diagrams.ts）。这里只出数据，画在 `lumiere_painter.dart`。
library;

import 'dart:math' as math;

import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_math.dart';

typedef Pt = (double, double);

class LinePath {
  LinePath({
    required this.points,
    this.width = 0.0016,
    this.alpha = 0.55,
    this.delay = 0,
    this.span = 0.4,
    this.dash,
  }) : lengths = _cumulative(points);

  final List<Pt> points;
  final double width;
  final double alpha;
  final double delay;
  final double span;
  final (double, double)? dash;

  /// 累计长度（描线进度按长度推进）。
  final List<double> lengths;

  double get total => lengths.isEmpty ? 0 : lengths.last;

  Pt get midpoint => points[points.length ~/ 2];

  static List<double> _cumulative(List<Pt> pts) {
    final List<double> out = <double>[0];
    for (int i = 1; i < pts.length; i++) {
      out.add(
        out[i - 1] +
            math.sqrt(
              math.pow(pts[i].$1 - pts[i - 1].$1, 2) +
                  math.pow(pts[i].$2 - pts[i - 1].$2, 2),
            ),
      );
    }
    return out;
  }
}

class LineNode {
  const LineNode(this.at, this.size, this.delay, this.twinklePhase);
  final Pt at;
  final double size;
  final double delay;
  final double twinklePhase;
}

class LineArtSpec {
  const LineArtSpec(this.paths, this.nodes);
  final List<LinePath> paths;
  final List<LineNode> nodes;

  static const LineArtSpec empty = LineArtSpec(<LinePath>[], <LineNode>[]);
}

LineArtSpec mergeArt(List<LineArtSpec> specs) => LineArtSpec(
  <LinePath>[for (final LineArtSpec s in specs) ...s.paths],
  <LineNode>[for (final LineArtSpec s in specs) ...s.nodes],
);

/// 线条样式（diagrams.ts 的 Style）：未给的项用各图元自己的默认值。
class ArtStyle {
  const ArtStyle({this.width, this.alpha, this.delay, this.span, this.dash});
  final double? width;
  final double? alpha;
  final double? delay;
  final double? span;
  final (double, double)? dash;
}

const ArtStyle _none = ArtStyle();

LinePath _path(
  List<Pt> points, {
  ArtStyle style = _none,
  double width = 0.0016,
  double alpha = 0.55,
  double delay = 0,
  double span = 0.4,
  (double, double)? dash,
}) => LinePath(
  points: points,
  width: style.width ?? width,
  alpha: style.alpha ?? alpha,
  delay: style.delay ?? delay,
  span: style.span ?? span,
  dash: style.dash ?? dash,
);

LinePath _seg(
  Pt a,
  Pt b, {
  double width = 0.0016,
  double alpha = 0.55,
  double delay = 0,
  double span = 0.4,
  (double, double)? dash,
}) => LinePath(
  points: <Pt>[a, b],
  width: width,
  alpha: alpha,
  delay: delay,
  span: span,
  dash: dash,
);

LineNode _node(
  Pt at, [
  double size = 0.018,
  double delay = 0.4,
  double phase = 0,
]) => LineNode(at, size, delay, phase);

double _d(ArtStyle s) => s.delay ?? 0;

List<Pt> arcPoints(
  double cx,
  double cy,
  double r,
  double from,
  double to, [
  int steps = 64,
]) => <Pt>[
  for (int i = 0; i <= steps; i++)
    (
      cx + math.cos(from + (to - from) * i / steps) * r,
      cy + math.sin(from + (to - from) * i / steps) * r,
    ),
];

List<Pt> cubicPoints(Pt p0, Pt p1, Pt p2, Pt p3, [int steps = 40]) => <Pt>[
  for (int i = 0; i <= steps; i++)
    () {
      final double t = i / steps;
      final double u = 1 - t;
      final double a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t;
      final double d = t * t * t;
      return (
        a * p0.$1 + b * p1.$1 + c * p2.$1 + d * p3.$1,
        a * p0.$2 + b * p1.$2 + c * p2.$2 + d * p3.$2,
      );
    }(),
];

List<Pt> ellipsePath(
  double cx,
  double cy,
  double rx,
  double ry, [
  double rotation = 0,
  double from = 0,
  double to = kTau,
  int steps = 96,
]) {
  final double c = math.cos(rotation);
  final double s = math.sin(rotation);
  return arcPoints(0, 0, 1, from, to, steps)
      .map(
        (Pt p) => (
          cx + p.$1 * rx * c - p.$2 * ry * s,
          cy + p.$1 * rx * s + p.$2 * ry * c,
        ),
      )
      .toList();
}

LinePath circle(double cx, double cy, double r, [ArtStyle style = _none]) =>
    _path(ellipsePath(cx, cy, r, r), style: style);

// ---------------------------------------------------------------------------
// recipes.ts
// ---------------------------------------------------------------------------

/// 量角器似的光环：下半圆外弧 + 内弧、辐条、外弧上的细刻度。
LineArtSpec protractorHalo({
  required double cx,
  required double cy,
  required double radius,
  double delay = 0,
  double alpha = 0.5,
  double spokeStep = math.pi / 12,
}) {
  const double from = math.pi * 0.04;
  const double to = math.pi * 0.96;
  final double inner = radius * 0.62;
  final List<LinePath> paths = <LinePath>[
    LinePath(
      points: arcPoints(cx, cy, radius, to, from, 96),
      width: 0.0016,
      alpha: alpha,
      delay: delay,
      span: 0.45,
    ),
    LinePath(
      points: arcPoints(cx, cy, inner, from, to, 72),
      width: 0.0013,
      alpha: alpha * 0.8,
      delay: delay + 0.08,
      span: 0.4,
    ),
    LinePath(
      points: arcPoints(cx, cy, radius * 1.18, from + 0.1, to - 0.1, 80),
      width: 0.0011,
      alpha: alpha * 0.45,
      delay: delay + 0.2,
      span: 0.4,
      dash: (0.004, 0.009),
    ),
  ];
  final List<LineNode> nodes = <LineNode>[];
  int index = 0;
  for (
    double a = math.pi / 2 - spokeStep * 5;
    a <= math.pi / 2 + spokeStep * 5 + 1e-6;
    a += spokeStep
  ) {
    final bool long = index.isEven;
    final double r0 = inner * 0.2;
    final double r1 = radius * (long ? 1.12 : 1.02);
    paths.add(
      _seg(
        (cx + math.cos(a) * r0, cy + math.sin(a) * r0),
        (cx + math.cos(a) * r1, cy + math.sin(a) * r1),
        width: long ? 0.0013 : 0.0009,
        alpha: alpha * (long ? 0.7 : 0.45),
        delay: delay + 0.12 + (a - math.pi / 2).abs() * 0.12,
        span: 0.3,
      ),
    );
    if (long) {
      nodes.add(
        LineNode(
          (cx + math.cos(a) * radius, cy + math.sin(a) * radius),
          0.022,
          delay + 0.45,
          index * 1.7,
        ),
      );
    }
    index++;
  }
  for (double a = from; a <= to; a += math.pi / 72) {
    paths.add(
      _seg(
        (cx + math.cos(a) * radius, cy + math.sin(a) * radius),
        (cx + math.cos(a) * radius * 0.975, cy + math.sin(a) * radius * 0.975),
        width: 0.0008,
        alpha: alpha * 0.4,
        delay: delay + 0.25 + (a - from) * 0.05,
        span: 0.15,
      ),
    );
  }
  return LineArtSpec(paths, nodes);
}

/// 取景框：大矩形、四角角标、边上刻度、两侧竖直点线。
LineArtSpec viewfinderFrame({
  required double aspect,
  required double left,
  required double top,
  required double right,
  required double bottom,
  double delay = 0,
  double alpha = 0.3,
}) {
  final double l = left * aspect;
  final double r = right * aspect;
  const double corner = 0.03;
  final List<LinePath> paths = <LinePath>[
    LinePath(
      points: <Pt>[(l, top), (r, top), (r, bottom), (l, bottom), (l, top)],
      width: 0.0009,
      alpha: alpha * 0.55,
      delay: delay,
      span: 0.6,
    ),
  ];
  final List<List<Pt>> corners = <List<Pt>>[
    <Pt>[(l, top + corner), (l, top), (l + corner, top)],
    <Pt>[(r - corner, top), (r, top), (r, top + corner)],
    <Pt>[(r, bottom - corner), (r, bottom), (r - corner, bottom)],
    <Pt>[(l + corner, bottom), (l, bottom), (l, bottom - corner)],
  ];
  for (int i = 0; i < corners.length; i++) {
    paths.add(
      LinePath(
        points: corners[i],
        width: 0.0018,
        alpha: alpha,
        delay: delay + 0.1 + i * 0.05,
        span: 0.2,
      ),
    );
  }
  const int ticks = 12;
  for (int i = 1; i < ticks; i++) {
    final double x = l + (r - l) * i / ticks;
    final double y = top + (bottom - top) * i / ticks;
    final double len = i % 3 == 0 ? 0.014 : 0.007;
    final double d = delay + 0.3 + i * 0.01;
    for (final (Pt, Pt) s in <(Pt, Pt)>[
      ((x, top), (x, top + len)),
      ((x, bottom), (x, bottom - len)),
      ((l, y), (l + len, y)),
      ((r, y), (r - len, y)),
    ]) {
      paths.add(
        _seg(
          s.$1,
          s.$2,
          width: 0.0008,
          alpha: alpha * 0.6,
          delay: d,
          span: 0.1,
        ),
      );
    }
  }
  final List<double> guideX = <double>[l + (r - l) * 0.14, r - (r - l) * 0.14];
  for (int i = 0; i < 2; i++) {
    paths.add(
      _seg(
        (guideX[i], top + 0.06),
        (guideX[i], bottom - 0.06),
        width: 0.001,
        alpha: alpha * 0.5,
        delay: delay + 0.35 + i * 0.05,
        span: 0.4,
        dash: (0.003, 0.012),
      ),
    );
  }
  return LineArtSpec(paths, const <LineNode>[]);
}

/// 萌芽：从画面底部升起的茎，顶端两片叶。
LineArtSpec sprout({
  required double cx,
  required double baseY,
  required double size,
  double delay = 0,
  double alpha = 0.55,
  double open = 1,
}) {
  final List<LinePath> paths = <LinePath>[
    LinePath(
      points: cubicPoints(
        (cx, 1.04),
        (cx + 0.01, 0.94),
        (cx - 0.008, baseY + 0.08),
        (cx, baseY),
      ),
      width: 0.0016,
      alpha: alpha,
      delay: delay,
      span: 0.3,
    ),
  ];
  final List<LineNode> nodes = <LineNode>[];
  void leaf(int side, int index) {
    final double lean = (0.2 + 0.2 * open) * math.pi;
    final Pt d = (math.sin(lean) * side, -math.cos(lean));
    final Pt n = (-d.$2, d.$1);
    final Pt base = (cx, baseY);
    final Pt tip = (base.$1 + d.$1 * size, base.$2 + d.$2 * size - size * 0.12);
    final double bulge = size * 0.34;
    Pt at(double along, double across) => (
      base.$1 + d.$1 * size * along + n.$1 * across,
      base.$2 +
          d.$2 * size * along +
          n.$2 * across -
          size * 0.12 * along * along,
    );
    final double ld = delay + 0.22 + index * 0.08;
    paths.add(
      LinePath(
        points: cubicPoints(
          base,
          at(0.3, bulge),
          at(0.78, bulge * 0.9),
          tip,
          48,
        ),
        width: 0.0026,
        alpha: alpha,
        delay: ld,
        span: 0.35,
      ),
    );
    paths.add(
      LinePath(
        points: cubicPoints(
          base,
          at(0.3, -bulge * 0.95),
          at(0.8, -bulge * 0.6),
          tip,
          48,
        ),
        width: 0.0026,
        alpha: alpha,
        delay: ld + 0.04,
        span: 0.35,
      ),
    );
    paths.add(
      LinePath(
        points: cubicPoints(
          base,
          at(0.35, bulge * 0.08),
          at(0.7, bulge * 0.05),
          tip,
          32,
        ),
        width: 0.0011,
        alpha: alpha * 0.7,
        delay: ld + 0.12,
        span: 0.3,
      ),
    );
    for (int v = 1; v <= 4; v++) {
      final double f = v / 5.2;
      final Pt start = at(f, bulge * 0.04);
      for (final int s in <int>[1, -1]) {
        final Pt end = at(f + 0.14, s * bulge * (0.72 - f * 0.35));
        paths.add(
          LinePath(
            points: cubicPoints(
              start,
              at(f + 0.04, s * bulge * 0.25),
              at(f + 0.1, s * bulge * 0.5),
              end,
              16,
            ),
            width: 0.0008,
            alpha: alpha * 0.45,
            delay: ld + 0.2 + v * 0.03,
            span: 0.18,
          ),
        );
      }
    }
    nodes.add(LineNode(tip, 0.03, ld + 0.3, index * 2.1));
    nodes.add(
      LineNode(at(0.45, bulge * 0.86), 0.014, ld + 0.33, index * 2.1 + 1),
    );
    nodes.add(
      LineNode(at(0.6, -bulge * 0.8), 0.012, ld + 0.36, index * 2.1 + 2),
    );
  }

  leaf(-1, 0);
  leaf(1, 1);
  nodes.add(LineNode((cx, baseY), 0.02, delay + 0.3, 0.5));
  return LineArtSpec(paths, nodes);
}

/// 散落的小闪点。
LineArtSpec scatteredSparks({
  required double aspect,
  required int count,
  required LumiereRng random,
  double delay = 0,
  (double, double, double, double) region = (0.05, 0.08, 0.95, 0.92),
}) {
  final (double x0, double y0, double x1, double y1) = region;
  return LineArtSpec(const <LinePath>[], <LineNode>[
    for (int i = 0; i < count; i++)
      () {
        final double x = (x0 + (x1 - x0) * random()) * aspect;
        final double y = y0 + (y1 - y0) * random();
        final double size = 0.006 + random() * 0.012;
        final double d = delay + random() * 0.5;
        return LineNode((x, y), size, d, i * 2.399);
      }(),
  ]);
}

LineArtSpec blindsWindow({
  required double x,
  required double y,
  required double w,
  required double h,
  required int slats,
  double delay = 0,
  double alpha = 0.5,
}) {
  final List<LinePath> paths = <LinePath>[
    LinePath(
      points: <Pt>[(x, y), (x + w, y), (x + w, y + h), (x, y + h), (x, y)],
      width: 0.0018,
      alpha: alpha,
      delay: delay,
      span: 0.5,
    ),
  ];
  for (int i = 1; i < slats; i++) {
    final double sy = y + h * i / slats;
    paths.add(
      _seg(
        (x, sy),
        (x + w, sy),
        width: 0.001,
        alpha: alpha * 0.6,
        delay: delay + 0.1 + i * 0.03,
        span: 0.2,
      ),
    );
  }
  return LineArtSpec(paths, <LineNode>[
    _node((x + w, y + h), 0.018, delay + 0.4, 1),
  ]);
}

LineArtSpec prismTriangle({
  required double cx,
  required double cy,
  required double size,
  double delay = 0,
  double alpha = 0.7,
}) {
  final double h = size * math.sqrt(3) / 2;
  final Pt top = (cx, cy - h * 2 / 3);
  final Pt left = (cx - size / 2, cy + h / 3);
  final Pt right = (cx + size / 2, cy + h / 3);
  return LineArtSpec(
    <LinePath>[
      LinePath(
        points: <Pt>[top, right, left, top],
        width: 0.0022,
        alpha: alpha,
        delay: delay,
        span: 0.45,
      ),
      _seg(
        top,
        (cx, cy + h / 3),
        width: 0.0009,
        alpha: alpha * 0.4,
        delay: delay + 0.2,
        span: 0.3,
        dash: (0.004, 0.006),
      ),
    ],
    <LineNode>[_node(top, 0.026, delay + 0.4, 0)],
  );
}

LineArtSpec slitBarrier({
  required double cx,
  required double y,
  required double width,
  required double gap,
  required double separation,
  double delay = 0,
  double alpha = 0.6,
}) {
  final double a = cx - separation / 2;
  final double b = cx + separation / 2;
  final List<(double, double)> segs = <(double, double)>[
    (cx - width / 2, a - gap / 2),
    (a + gap / 2, b - gap / 2),
    (b + gap / 2, cx + width / 2),
  ];
  return LineArtSpec(
    <LinePath>[
      for (int i = 0; i < segs.length; i++)
        _seg(
          (segs[i].$1, y),
          (segs[i].$2, y),
          width: 0.0026,
          alpha: alpha,
          delay: delay + i * 0.08,
          span: 0.3,
        ),
    ],
    <LineNode>[
      _node((a, y), 0.022, delay + 0.35, 0),
      _node((b, y), 0.022, delay + 0.4, 2),
    ],
  );
}

// ---------------------------------------------------------------------------
// diagrams.ts
// ---------------------------------------------------------------------------

LineArtSpec rays(
  double cx,
  double cy,
  double r0,
  double r1,
  int count, {
  double from = 0,
  double to = kTau,
  ArtStyle style = _none,
}) => LineArtSpec(<LinePath>[
  for (int i = 0; i < count; i++)
    () {
      final double a =
          from +
          (to - from) * (i + (to - from >= kTau - 1e-6 ? 0 : 0.5)) / count;
      return _seg(
        (cx + math.cos(a) * r0, cy + math.sin(a) * r0),
        (cx + math.cos(a) * r1, cy + math.sin(a) * r1),
        width: style.width ?? 0.001,
        alpha: style.alpha ?? 0.4,
        delay: _d(style) + i / count * 0.3,
        span: style.span ?? 0.2,
      );
    }(),
], const <LineNode>[]);

LineArtSpec _concentric(
  double cx,
  double cy,
  List<double> radii, [
  ArtStyle style = _none,
]) => LineArtSpec(<LinePath>[
  for (int i = 0; i < radii.length; i++)
    LinePath(
      points: ellipsePath(cx, cy, radii[i], radii[i]),
      width: style.width ?? 0.0011,
      alpha: style.alpha ?? 0.45,
      delay: _d(style) + i * 0.06,
      span: style.span ?? 0.4,
    ),
], const <LineNode>[]);

LinePath _rect(
  double x,
  double y,
  double w,
  double h,
  ArtStyle s,
  double width,
  double alpha,
) => _path(
  <Pt>[(x, y), (x + w, y), (x + w, y + h), (x, y + h), (x, y)],
  style: s,
  width: width,
  alpha: alpha,
);

LineArtSpec crossWindow(
  double x,
  double y,
  double w,
  double h, [
  ArtStyle s = _none,
]) => LineArtSpec(
  <LinePath>[
    _rect(x, y, w, h, s, 0.002, 0.55),
    _seg(
      (x + w / 2, y),
      (x + w / 2, y + h),
      width: 0.0014,
      alpha: 0.45,
      delay: _d(s) + 0.15,
    ),
    _seg(
      (x, y + h / 2),
      (x + w, y + h / 2),
      width: 0.0014,
      alpha: 0.45,
      delay: _d(s) + 0.2,
    ),
  ],
  <LineNode>[_node((x + w / 2, y + h / 2), 0.02, _d(s) + 0.4)],
);

LineArtSpec archWindow(
  double x,
  double y,
  double w,
  double h, [
  ArtStyle s = _none,
]) {
  final double r = w / 2;
  final double top = y + r;
  return LineArtSpec(
    <LinePath>[
      _path(
        <Pt>[
          (x, y + h),
          (x, top),
          ...arcPoints(x + r, top, r, math.pi, kTau, 40),
          (x + w, y + h),
          (x, y + h),
        ],
        style: s,
        width: 0.0018,
        alpha: 0.55,
      ),
      _seg(
        (x + r, y),
        (x + r, y + h),
        width: 0.001,
        alpha: 0.35,
        delay: _d(s) + 0.2,
      ),
    ],
    <LineNode>[_node((x + r, y + 0.01), 0.018, _d(s) + 0.4)],
  );
}

LineArtSpec roseWindow(double cx, double cy, double r) =>
    mergeArt(<LineArtSpec>[
      _concentric(cx, cy, <double>[
        r,
        r * 0.62,
        r * 0.22,
      ], const ArtStyle(width: 0.0016, alpha: 0.55)),
      rays(cx, cy, r * 0.22, r, 12, style: const ArtStyle(delay: 0.2)),
      LineArtSpec(
        <LinePath>[
          for (int i = 0; i < 12; i++)
            circle(
              cx + math.cos(i / 12 * kTau) * r * 0.8,
              cy + math.sin(i / 12 * kTau) * r * 0.8,
              r * 0.14,
              ArtStyle(width: 0.0009, alpha: 0.35, delay: 0.35 + i * 0.02),
            ),
        ],
        <LineNode>[_node((cx, cy), 0.028, 0.5)],
      ),
    ]);

LineArtSpec doorSlit(double cx, double top, double bottom, double gap) =>
    LineArtSpec(
      <LinePath>[
        _seg((cx - gap / 2, top), (cx - gap / 2, bottom), width: 0.0018),
        _seg(
          (cx + gap / 2, top),
          (cx + gap / 2, bottom),
          width: 0.0018,
          delay: 0.05,
        ),
        _seg(
          (cx - gap / 2 - 0.25, bottom),
          (cx + gap / 2 + 0.25, bottom),
          width: 0.001,
          alpha: 0.35,
          delay: 0.2,
        ),
      ],
      <LineNode>[_node((cx, top + 0.02), 0.02, 0.4)],
    );

LineArtSpec gridPanel(
  double x,
  double y,
  double w,
  double h,
  int cols,
  int rows, {
  bool diagonal = false,
  ArtStyle style = _none,
}) {
  final List<LinePath> paths = <LinePath>[
    _rect(x, y, w, h, style, 0.0018, 0.5),
  ];
  final double d = _d(style) + 0.15;
  LinePath inner(Pt a, Pt b) =>
      _seg(a, b, width: 0.0009, alpha: 0.32, delay: d, span: 0.25);
  if (diagonal) {
    final int n = cols + rows;
    for (int i = 1; i < n; i++) {
      final double t = i / n;
      paths.add(
        inner(
          (x + w * math.min(1, t * 2), y + h * math.max(0, t * 2 - 1)),
          (x + w * math.max(0, t * 2 - 1), y + h * math.min(1, t * 2)),
        ),
      );
      paths.add(
        inner(
          (x + w * (1 - math.min(1, t * 2)), y + h * math.max(0, t * 2 - 1)),
          (x + w * (1 - math.max(0, t * 2 - 1)), y + h * math.min(1, t * 2)),
        ),
      );
    }
  } else {
    for (int i = 1; i < cols; i++) {
      paths.add(inner((x + w * i / cols, y), (x + w * i / cols, y + h)));
    }
    for (int j = 1; j < rows; j++) {
      paths.add(inner((x, y + h * j / rows), (x + w, y + h * j / rows)));
    }
  }
  return LineArtSpec(paths, const <LineNode>[]);
}

LineArtSpec tallWindows(double x0, double x1, double y, double h, int count) =>
    mergeArt(<LineArtSpec>[
      for (int i = 0; i < count; i++)
        () {
          final double w = (x1 - x0) / count * 0.45;
          final double x = x0 + (x1 - x0) * (i + 0.5) / count - w / 2;
          return archWindow(x, y, w, h, ArtStyle(alpha: 0.45, delay: i * 0.07));
        }(),
    ]);

LineArtSpec shards(double aspect, LumiereRng random, int count) =>
    LineArtSpec(<LinePath>[
      for (int i = 0; i < count; i++)
        () {
          final double cx = (0.1 + random() * 0.8) * aspect;
          final double cy = 0.12 + random() * 0.76;
          final double r = 0.025 + random() * 0.05;
          final double a = random() * kTau;
          final List<Pt> pts = <Pt>[
            for (final int k in <int>[0, 1, 2, 0])
              (
                cx + math.cos(a + k * kTau / 3) * r,
                cy + math.sin(a + k * kTau / 3) * r * (0.7 + random() * 0.6),
              ),
          ];
          return LinePath(
            points: pts,
            width: 0.0014,
            alpha: 0.5,
            delay: i * 0.04,
            span: 0.25,
          );
        }(),
    ], const <LineNode>[]);

LineArtSpec spectrumLines(
  double x0,
  double x1,
  double y,
  double h,
  LumiereRng random,
  int count,
) => LineArtSpec(<LinePath>[
  _seg((x0, y + h / 2), (x1, y + h / 2), width: 0.001, alpha: 0.35),
  for (int i = 0; i < count; i++)
    () {
      final double x = x0 + (x1 - x0) * (0.05 + 0.9 * random());
      final double k = 0.3 + random() * 0.7;
      return _seg(
        (x, y + h / 2),
        (x, y + h / 2 - h * k),
        width: 0.0012 + random() * 0.0012,
        alpha: 0.4 + k * 0.3,
        delay: 0.1 + i * 0.03,
        span: 0.2,
      );
    }(),
], const <LineNode>[]);

LineArtSpec cubeSplitter(double cx, double cy, double size) => LineArtSpec(
  <LinePath>[
    _rect(cx - size / 2, cy - size / 2, size, size, _none, 0.002, 0.6),
    _seg(
      (cx - size / 2, cy + size / 2),
      (cx + size / 2, cy - size / 2),
      width: 0.0012,
      alpha: 0.45,
      delay: 0.2,
    ),
  ],
  <LineNode>[_node((cx, cy), 0.022, 0.35)],
);

LineArtSpec rainbowArcs(double cx, double cy, double r) =>
    LineArtSpec(<LinePath>[
      LinePath(
        points: arcPoints(cx, cy, r, math.pi * 1.08, math.pi * 1.92, 72),
        width: 0.0018,
        alpha: 0.5,
      ),
      LinePath(
        points: arcPoints(cx, cy, r * 1.18, math.pi * 1.1, math.pi * 1.9, 72),
        width: 0.001,
        alpha: 0.3,
        delay: 0.15,
        dash: (0.006, 0.01),
      ),
      circle(
        cx,
        cy - r * 0.4,
        0.03,
        const ArtStyle(width: 0.0012, alpha: 0.45, delay: 0.3),
      ),
    ], const <LineNode>[]);

LineArtSpec glassCup(double cx, double top, double w, double h) => LineArtSpec(
  <LinePath>[
    LinePath(
      points: ellipsePath(cx, top, w / 2, w * 0.12),
      width: 0.0016,
      alpha: 0.5,
    ),
    LinePath(
      points: <Pt>[
        (cx - w / 2, top),
        (cx - w * 0.4, top + h),
        (cx + w * 0.4, top + h),
        (cx + w / 2, top),
      ],
      width: 0.0016,
      alpha: 0.5,
      delay: 0.1,
    ),
    LinePath(
      points: ellipsePath(cx, top + h, w * 0.4, w * 0.09, 0, 0, math.pi),
      width: 0.001,
      alpha: 0.35,
      delay: 0.2,
    ),
  ],
  <LineNode>[_node((cx - w * 0.3, top + h * 0.3), 0.016, 0.35)],
);

LineArtSpec ripples(double cx, double cy, double r, int count) => LineArtSpec(
  <LinePath>[
    for (int i = 0; i < count; i++)
      LinePath(
        points: ellipsePath(
          cx,
          cy,
          r * (i + 1) / count,
          r * 0.3 * (i + 1) / count,
        ),
        width: 0.0012,
        alpha: 0.5 - i * 0.07,
        delay: i * 0.08,
      ),
  ],
  <LineNode>[_node((cx, cy), 0.02, 0.3)],
);

LineArtSpec waterline(
  double aspect,
  double y,
  double amplitude,
  double waves,
) => LineArtSpec(<LinePath>[
  LinePath(
    points: <Pt>[
      for (int i = 0; i <= 120; i++)
        (i / 120 * aspect, y + math.sin(i / 120 * waves * kTau) * amplitude),
    ],
    width: 0.0014,
    alpha: 0.45,
    span: 0.6,
  ),
], const <LineNode>[]);

LineArtSpec magnifier(double cx, double cy, double r) => LineArtSpec(<LinePath>[
  circle(cx, cy, r, const ArtStyle(width: 0.0022, alpha: 0.6)),
  circle(
    cx,
    cy,
    r * 0.9,
    const ArtStyle(width: 0.0009, alpha: 0.3, delay: 0.1),
  ),
  _seg(
    (cx + r * 0.7, cy + r * 0.7),
    (cx + r * 1.6, cy + r * 1.6),
    width: 0.004,
    alpha: 0.5,
    delay: 0.2,
  ),
], const <LineNode>[]);

LineArtSpec crystal(double cx, double cy, double r) {
  final List<Pt> outer = <Pt>[
    for (int i = 0; i < 7; i++)
      (cx + math.cos(i * kTau / 6) * r, cy + math.sin(i * kTau / 6) * r * 1.3),
  ];
  return LineArtSpec(
    <LinePath>[
      LinePath(points: outer, width: 0.002, alpha: 0.55),
      for (int i = 0; i < 3; i++)
        _seg(
          outer[i],
          outer[i + 3],
          width: 0.0009,
          alpha: 0.3,
          delay: 0.15 + i * 0.05,
        ),
    ],
    <LineNode>[
      for (int i = 0; i < 6; i += 2) _node(outer[i], 0.016, 0.4, i / 2),
    ],
  );
}

LineArtSpec lens(
  double cx,
  double cy,
  double h,
  bool convex,
  double aspect, [
  ArtStyle s = _none,
]) {
  final double bulge = h * 0.18;
  final Pt top = (cx, cy - h / 2);
  final Pt bottom = (cx, cy + h / 2);
  List<Pt> side(double sign) {
    final double off =
        sign * (convex ? bulge : -bulge * 0.2) +
        (convex ? 0 : sign * bulge * 0.6);
    return cubicPoints(
      top,
      (cx + off, cy - h / 4),
      (cx + off, cy + h / 4),
      bottom,
      32,
    );
  }

  final List<Pt> outline = convex
      ? <Pt>[...side(1), ...side(-1).reversed]
      : <Pt>[
          (cx - bulge * 0.7, cy - h / 2),
          (cx + bulge * 0.7, cy - h / 2),
          ...cubicPoints(
            (cx + bulge * 0.7, cy - h / 2),
            (cx + bulge * 0.1, cy - h / 4),
            (cx + bulge * 0.1, cy + h / 4),
            (cx + bulge * 0.7, cy + h / 2),
            24,
          ),
          (cx - bulge * 0.7, cy + h / 2),
          ...cubicPoints(
            (cx - bulge * 0.7, cy + h / 2),
            (cx - bulge * 0.1, cy + h / 4),
            (cx - bulge * 0.1, cy - h / 4),
            (cx - bulge * 0.7, cy - h / 2),
            24,
          ),
        ];
  return LineArtSpec(<LinePath>[
    _path(outline, style: s, width: 0.002, alpha: 0.6),
    _seg(
      (aspect * 0.05, cy),
      (aspect * 0.95, cy),
      width: 0.0009,
      alpha: 0.3,
      delay: _d(s) + 0.1,
      dash: (0.008, 0.008),
      span: 0.5,
    ),
  ], const <LineNode>[]);
}

LineArtSpec rayPath(List<Pt> points, {double delay = 0}) => LineArtSpec(
  <LinePath>[
    LinePath(
      points: points,
      width: 0.0014,
      alpha: 0.6,
      span: 0.5,
      delay: delay,
    ),
  ],
  <LineNode>[_node(points.last, 0.016, delay + 0.5, points.length.toDouble())],
);

LineArtSpec focusMark(double x, double y, {double delay = 0}) => LineArtSpec(
  <LinePath>[
    _seg(
      (x - 0.012, y),
      (x + 0.012, y),
      width: 0.0012,
      alpha: 0.55,
      delay: delay,
    ),
    _seg(
      (x, y - 0.012),
      (x, y + 0.012),
      width: 0.0012,
      alpha: 0.55,
      delay: delay,
    ),
  ],
  <LineNode>[_node((x, y), 0.024, delay + 0.3)],
);

LineArtSpec mirror(
  double cx,
  double cy,
  double length,
  double angle, {
  double delay = 0,
}) {
  final double dx = math.cos(angle) * length / 2;
  final double dy = math.sin(angle) * length / 2;
  final double nx = -math.sin(angle);
  final double ny = math.cos(angle);
  final double back = math.atan2(-ny, -nx);
  return LineArtSpec(<LinePath>[
    _seg(
      (cx - dx, cy - dy),
      (cx + dx, cy + dy),
      width: 0.003,
      alpha: 0.6,
      delay: delay,
    ),
    for (int i = 0; i < 10; i++)
      () {
        final double t = -0.45 + i / 9 * 0.9;
        final double bx = cx + dx * 2 * t;
        final double by = cy + dy * 2 * t;
        return _seg(
          (bx, by),
          (bx + nx * 0.015 - dx * 0.04, by + ny * 0.015 - dy * 0.04),
          width: 0.0008,
          alpha: 0.3,
          delay: delay + 0.2 + i * 0.01,
          span: 0.1,
        );
      }(),
    _seg(
      (cx, cy),
      (cx - nx * length * 0.5, cy - ny * length * 0.5),
      width: 0.0009,
      alpha: 0.35,
      delay: delay + 0.25,
      dash: (0.006, 0.006),
    ),
    LinePath(
      points: arcPoints(cx, cy, length * 0.12, back - 0.5, back + 0.5, 20),
      width: 0.0009,
      alpha: 0.4,
      delay: delay + 0.35,
    ),
  ], const <LineNode>[]);
}

LineArtSpec interfaceLine(double aspect, double y) => LineArtSpec(<LinePath>[
  _seg(
    (aspect * 0.06, y),
    (aspect * 0.94, y),
    width: 0.002,
    alpha: 0.55,
    span: 0.5,
  ),
  for (int i = 0; i < 24; i++)
    () {
      final double x = aspect * (0.08 + i / 23 * 0.84);
      return _seg(
        (x, y + 0.01),
        (x - 0.02, y + 0.04),
        width: 0.0008,
        alpha: 0.22,
        delay: 0.2 + i * 0.01,
        span: 0.1,
      );
    }(),
], const <LineNode>[]);

LineArtSpec ruler(
  double x0,
  double x1,
  double y,
  int ticks, {
  double delay = 0,
}) => LineArtSpec(<LinePath>[
  _seg((x0, y), (x1, y), width: 0.0016, alpha: 0.5, delay: delay, span: 0.5),
  for (int i = 0; i <= ticks; i++)
    () {
      final double x = x0 + (x1 - x0) * i / ticks;
      return _seg(
        (x, y),
        (x, y + (i % 5 == 0 ? 0.02 : 0.01)),
        width: 0.0008,
        alpha: 0.4,
        delay: delay + 0.2 + i * 0.005,
        span: 0.08,
      );
    }(),
], const <LineNode>[]);

LineArtSpec fiber(Pt a, Pt b, Pt c, Pt d, double thickness) {
  final List<Pt> center = cubicPoints(a, b, c, d, 60);
  List<Pt> offset(double sign) => <Pt>[
    for (int i = 0; i < center.length; i++)
      () {
        final Pt p0 = center[math.max(0, i - 1)];
        final Pt p1 = center[math.min(center.length - 1, i + 1)];
        final double dx = p1.$1 - p0.$1;
        final double dy = p1.$2 - p0.$2;
        double len = math.sqrt(dx * dx + dy * dy);
        if (len == 0) len = 1;
        return (
          center[i].$1 - dy / len * thickness * sign,
          center[i].$2 + dx / len * thickness * sign,
        );
      }(),
  ];
  return LineArtSpec(
    <LinePath>[
      LinePath(points: offset(1), width: 0.0014, alpha: 0.5, span: 0.6),
      LinePath(
        points: offset(-1),
        width: 0.0014,
        alpha: 0.5,
        delay: 0.05,
        span: 0.6,
      ),
    ],
    <LineNode>[_node(center.last, 0.024, 0.6)],
  );
}

LineArtSpec pinholeBox(double cx, double cy, double w, double h) => LineArtSpec(
  <LinePath>[
    _rect(cx - w / 2, cy - h / 2, w, h, _none, 0.0018, 0.5),
    _seg(
      (cx - w / 2 - 0.25, cy - h * 0.35),
      (cx - w / 2 - 0.25, cy + h * 0.35),
      width: 0.0016,
      alpha: 0.45,
      delay: 0.1,
    ),
    _seg(
      (cx + w / 2 - 0.02, cy + h * 0.28),
      (cx + w / 2 - 0.02, cy - h * 0.28),
      width: 0.0014,
      alpha: 0.4,
      delay: 0.3,
      dash: (0.005, 0.005),
    ),
    _seg(
      (cx - w / 2 - 0.25, cy - h * 0.35),
      (cx + w / 2 - 0.02, cy + h * 0.28),
      width: 0.0008,
      alpha: 0.3,
      delay: 0.2,
    ),
    _seg(
      (cx - w / 2 - 0.25, cy + h * 0.35),
      (cx + w / 2 - 0.02, cy - h * 0.28),
      width: 0.0008,
      alpha: 0.3,
      delay: 0.2,
    ),
  ],
  <LineNode>[_node((cx - w / 2, cy), 0.02, 0.3)],
);

LineArtSpec ringsArt(
  double cx,
  double cy,
  double r,
  int count, [
  ArtStyle s = _none,
]) => _concentric(cx, cy, <double>[
  for (int i = 0; i < count; i++) r * math.sqrt((i + 1) / count),
], s);

LineArtSpec grating(double cx, double y, double width, int slits) =>
    LineArtSpec(<LinePath>[
      _seg(
        (cx - width / 2, y),
        (cx + width / 2, y),
        width: 0.0022,
        alpha: 0.55,
      ),
      for (int i = 0; i < slits; i++)
        () {
          final double x =
              cx - width * 0.3 + width * 0.6 * i / math.max(1, slits - 1);
          return _seg(
            (x, y - 0.01),
            (x, y + 0.01),
            width: 0.0008,
            alpha: 0.4,
            delay: 0.15 + i * 0.01,
            span: 0.1,
          );
        }(),
    ], const <LineNode>[]);

LineArtSpec twoSources(double cx, double cy, double separation, double r) =>
    mergeArt(<LineArtSpec>[
      _concentric(cx - separation / 2, cy, <double>[
        r * 0.25,
        r * 0.5,
        r * 0.75,
        r,
      ], const ArtStyle(alpha: 0.3)),
      _concentric(cx + separation / 2, cy, <double>[
        r * 0.25,
        r * 0.5,
        r * 0.75,
        r,
      ], const ArtStyle(alpha: 0.3, delay: 0.1)),
      LineArtSpec(const <LinePath>[], <LineNode>[
        _node((cx - separation / 2, cy), 0.024, 0.3),
        _node((cx + separation / 2, cy), 0.024, 0.35, 1),
      ]),
    ]);

LineArtSpec moire(
  double cx,
  double cy,
  double size,
  int count,
  double rotation,
) {
  List<LinePath> set(double angle, double delay) => <LinePath>[
    for (int i = 0; i < count; i++)
      () {
        final double t = -0.5 + i / (count - 1);
        final double ox = math.cos(angle + math.pi / 2) * t * size;
        final double oy = math.sin(angle + math.pi / 2) * t * size;
        return _seg(
          (
            cx + ox - math.cos(angle) * size / 2,
            cy + oy - math.sin(angle) * size / 2,
          ),
          (
            cx + ox + math.cos(angle) * size / 2,
            cy + oy + math.sin(angle) * size / 2,
          ),
          width: 0.0008,
          alpha: 0.3,
          delay: delay + i * 0.008,
          span: 0.15,
        );
      }(),
  ];
  return LineArtSpec(<LinePath>[
    ...set(0, 0),
    ...set(rotation, 0.2),
  ], const <LineNode>[]);
}

LineArtSpec standingWave(
  double x0,
  double x1,
  double y,
  double amplitude,
  int loops,
) => LineArtSpec(
  <LinePath>[
    for (int j = 0; j < 4; j++)
      () {
        final double k = const <double>[-1, -0.5, 0.5, 1][j];
        return LinePath(
          points: <Pt>[
            for (int i = 0; i <= 120; i++)
              (
                x0 + (x1 - x0) * i / 120,
                y + math.sin(i / 120 * loops * math.pi) * amplitude * k,
              ),
          ],
          width: 0.0012,
          alpha: 0.35 + k.abs() * 0.2,
          delay: j * 0.06,
          span: 0.5,
        );
      }(),
  ],
  <LineNode>[
    for (int i = 0; i <= loops; i++)
      _node((x0 + (x1 - x0) * i / loops, y), 0.014, 0.5, i.toDouble()),
  ],
);

LineArtSpec polarizers(
  double cx,
  double cy,
  double r,
  double gap,
  double rotation,
) {
  List<LinePath> disc(double x, double angle, double delay) => <LinePath>[
    circle(x, cy, r, ArtStyle(width: 0.0016, alpha: 0.5, delay: delay)),
    for (int i = 0; i < 7; i++)
      () {
        final double t = -0.75 + i / 6 * 1.5;
        final double half = math.sqrt(math.max(0, 1 - t * t)) * r;
        final double ox = -math.sin(angle) * t * r;
        final double oy = math.cos(angle) * t * r;
        return _seg(
          (x + ox - math.cos(angle) * half, cy + oy - math.sin(angle) * half),
          (x + ox + math.cos(angle) * half, cy + oy + math.sin(angle) * half),
          width: 0.0008,
          alpha: 0.3,
          delay: delay + 0.15 + i * 0.02,
          span: 0.15,
        );
      }(),
  ];
  return LineArtSpec(<LinePath>[
    ...disc(cx - gap / 2, 0, 0),
    ...disc(cx + gap / 2, rotation, 0.2),
  ], const <LineNode>[]);
}

LineArtSpec bigLeaf(double cx, double cy, double length, double angle) {
  final Pt d = (math.cos(angle), math.sin(angle));
  final Pt n = (-d.$2, d.$1);
  Pt at(double along, double across) => (
    cx + d.$1 * length * (along - 0.5) + n.$1 * across,
    cy + d.$2 * length * (along - 0.5) + n.$2 * across,
  );
  final double bulge = length * 0.3;
  final List<LinePath> paths = <LinePath>[
    LinePath(
      points: cubicPoints(
        at(0, 0),
        at(0.3, bulge),
        at(0.75, bulge * 0.8),
        at(1, 0),
        48,
      ),
      width: 0.002,
      alpha: 0.6,
    ),
    LinePath(
      points: cubicPoints(
        at(0, 0),
        at(0.3, -bulge),
        at(0.75, -bulge * 0.8),
        at(1, 0),
        48,
      ),
      width: 0.002,
      alpha: 0.6,
      delay: 0.05,
    ),
    LinePath(
      points: <Pt>[at(-0.12, 0), at(1, 0)],
      width: 0.0014,
      alpha: 0.5,
      delay: 0.15,
    ),
  ];
  for (int v = 1; v <= 6; v++) {
    final double f = v / 7.5;
    for (final int s in <int>[1, -1]) {
      paths.add(
        LinePath(
          points: cubicPoints(
            at(f, 0),
            at(f + 0.05, s * bulge * 0.3),
            at(f + 0.1, s * bulge * 0.55),
            at(f + 0.15, s * bulge * (0.8 - f * 0.35)),
            16,
          ),
          width: 0.0009,
          alpha: 0.4,
          delay: 0.25 + v * 0.05,
          span: 0.18,
        ),
      );
    }
  }
  return LineArtSpec(paths, <LineNode>[_node(at(1, 0), 0.026, 0.6)]);
}

LineArtSpec canopy(double aspect, LumiereRng random) {
  final List<LinePath> paths = <LinePath>[];
  void grow(
    double x,
    double y,
    double angle,
    double length,
    int depth,
    double delay,
  ) {
    final double x1 = x + math.cos(angle) * length;
    final double y1 = y + math.sin(angle) * length;
    paths.add(
      _seg(
        (x, y),
        (x1, y1),
        width: 0.0008 + depth * 0.0005,
        alpha: 0.3 + depth * 0.08,
        delay: delay,
        span: 0.2,
      ),
    );
    if (depth <= 0) return;
    grow(
      x1,
      y1,
      angle - 0.35 - random() * 0.3,
      length * 0.72,
      depth - 1,
      delay + 0.08,
    );
    grow(
      x1,
      y1,
      angle + 0.35 + random() * 0.3,
      length * 0.72,
      depth - 1,
      delay + 0.08,
    );
  }

  const List<double> xs = <double>[0.08, 0.35, 0.65, 0.92];
  for (int i = 0; i < xs.length; i++) {
    grow(
      xs[i] * aspect,
      -0.02,
      math.pi / 2 + (random() - 0.5) * 0.6,
      0.14,
      4,
      i * 0.05,
    );
  }
  return LineArtSpec(paths, const <LineNode>[]);
}

LineArtSpec fernCurl(double cx, double cy, double r) {
  final List<Pt> spiral = <Pt>[
    for (int i = 0; i < 140; i++)
      () {
        final double t = i / 139;
        final double a = t * kTau * 2.2;
        final double rr = r * math.exp(-t * 2.4);
        return (cx + math.cos(a) * rr, cy + math.sin(a) * rr);
      }(),
  ];
  return LineArtSpec(<LinePath>[
    LinePath(
      points: <Pt>[(cx + r, cy), (cx + r, cy + r * 2.2)],
      width: 0.0016,
      alpha: 0.5,
    ),
    LinePath(points: spiral, width: 0.0016, alpha: 0.55, delay: 0.1, span: 0.5),
    for (int i = 0; i < 9; i++)
      circle(
        spiral[(i / 9 * 90).floor()].$1,
        spiral[(i / 9 * 90).floor()].$2,
        0.008 + (1 - i / 9) * 0.01,
        ArtStyle(width: 0.0008, alpha: 0.35, delay: 0.4 + i * 0.03, span: 0.1),
      ),
  ], const <LineNode>[]);
}

LineArtSpec seedRoots(double cx, double cy, LumiereRng random) => LineArtSpec(
  <LinePath>[
    LinePath(
      points: ellipsePath(cx, cy, 0.025, 0.035, 0.3),
      width: 0.002,
      alpha: 0.6,
    ),
    for (int i = 0; i < 6; i++)
      () {
        final double spread = (i - 2.5) * 0.05;
        return LinePath(
          points: cubicPoints(
            (cx, cy + 0.03),
            (cx + spread * 0.4, cy + 0.08),
            (cx + spread, cy + 0.12),
            (
              cx + spread * 1.4 + (random() - 0.5) * 0.04,
              cy + 0.2 + random() * 0.06,
            ),
            24,
          ),
          width: 0.0009,
          alpha: 0.4,
          delay: 0.2 + i * 0.05,
          span: 0.35,
        );
      }(),
  ],
  <LineNode>[_node((cx, cy - 0.04), 0.03, 0.2)],
);

LineArtSpec bloomArt(double cx, double cy, double r, int petals) => LineArtSpec(
  <LinePath>[
    for (int i = 0; i < petals; i++)
      () {
        final double a = i / petals * kTau;
        final Pt d = (math.cos(a), math.sin(a));
        final Pt n = (-d.$2, d.$1);
        final Pt tip = (cx + d.$1 * r, cy + d.$2 * r);
        final double w = r * 0.35;
        return LinePath(
          points: <Pt>[
            ...cubicPoints(
              (cx, cy),
              (cx + d.$1 * r * 0.4 + n.$1 * w, cy + d.$2 * r * 0.4 + n.$2 * w),
              (
                cx + d.$1 * r * 0.9 + n.$1 * w * 0.6,
                cy + d.$2 * r * 0.9 + n.$2 * w * 0.6,
              ),
              tip,
              20,
            ),
            ...cubicPoints(
              tip,
              (
                cx + d.$1 * r * 0.9 - n.$1 * w * 0.6,
                cy + d.$2 * r * 0.9 - n.$2 * w * 0.6,
              ),
              (cx + d.$1 * r * 0.4 - n.$1 * w, cy + d.$2 * r * 0.4 - n.$2 * w),
              (cx, cy),
              20,
            ),
          ],
          width: 0.0016,
          alpha: 0.5,
          delay: i * 0.05,
          span: 0.3,
        );
      }(),
    circle(
      cx,
      cy,
      r * 0.12,
      const ArtStyle(width: 0.0012, alpha: 0.5, delay: 0.4),
    ),
  ],
  <LineNode>[_node((cx, cy), 0.03, 0.5)],
);

LineArtSpec vine(
  double x,
  double bottom,
  double top,
  double amplitude,
  double turns,
) => LineArtSpec(
  <LinePath>[
    LinePath(
      points: <Pt>[
        for (int i = 0; i <= 160; i++)
          (
            x +
                math.sin(i / 160 * turns * kTau) *
                    amplitude *
                    (1 - i / 160 * 0.4),
            bottom + (top - bottom) * i / 160,
          ),
      ],
      width: 0.0016,
      alpha: 0.55,
      span: 0.7,
    ),
    _seg(
      (x, bottom),
      (x, top),
      width: 0.0008,
      alpha: 0.25,
      delay: 0.1,
      dash: (0.005, 0.008),
      span: 0.5,
    ),
  ],
  <LineNode>[_node((x, top), 0.024, 0.7)],
);

LineArtSpec cells(
  double cx,
  double cy,
  double r,
  LumiereRng random,
  int count,
) => LineArtSpec(<LinePath>[
  circle(cx, cy, r, const ArtStyle(width: 0.0022, alpha: 0.5)),
  for (int i = 0; i < count; i++)
    () {
      final double a = random() * kTau;
      final double d = math.sqrt(random()) * r * 0.8;
      final double rx = 0.012 + random() * 0.012;
      final double ry = 0.008 + random() * 0.008;
      final double rot = random() * math.pi;
      return LinePath(
        points: ellipsePath(
          cx + math.cos(a) * d,
          cy + math.sin(a) * d,
          rx,
          ry,
          rot,
        ),
        width: 0.0009,
        alpha: 0.4,
        delay: 0.15 + i * 0.02,
        span: 0.15,
      );
    }(),
], const <LineNode>[]);

LineArtSpec molecule(double cx, double cy, double r, {double delay = 0}) {
  final List<Pt> hex = <Pt>[
    for (int i = 0; i < 7; i++)
      (
        cx + math.cos(i * kTau / 6 + math.pi / 6) * r,
        cy + math.sin(i * kTau / 6 + math.pi / 6) * r,
      ),
  ];
  Pt out(int k) =>
      (hex[k].$1 + (hex[k].$1 - cx) * 0.8, hex[k].$2 + (hex[k].$2 - cy) * 0.8);
  return LineArtSpec(
    <LinePath>[
      LinePath(points: hex, width: 0.0018, alpha: 0.55, delay: delay),
      circle(
        cx,
        cy,
        r * 0.55,
        ArtStyle(width: 0.001, alpha: 0.35, delay: delay + 0.2),
      ),
      for (int i = 0; i < 3; i++)
        _seg(
          hex[i * 2],
          out(i * 2),
          width: 0.0012,
          alpha: 0.45,
          delay: delay + 0.3 + i * 0.05,
        ),
    ],
    <LineNode>[
      for (int i = 0; i < 3; i++)
        _node(out(i * 2), 0.02, delay + 0.45, i.toDouble()),
    ],
  );
}

LineArtSpec orbits(
  double cx,
  double cy,
  List<double> radii,
  double tilt,
  double flatten,
  LumiereRng random,
) => LineArtSpec(
  <LinePath>[
    for (int i = 0; i < radii.length; i++)
      LinePath(
        points: ellipsePath(cx, cy, radii[i], radii[i] * flatten, tilt),
        width: 0.0012,
        alpha: 0.45,
        delay: i * 0.07,
        span: 0.5,
      ),
  ],
  <LineNode>[
    _node((cx, cy), 0.04, 0.2),
    for (int i = 0; i < radii.length; i++)
      () {
        final double a = random() * kTau;
        final Pt p = ellipsePath(
          cx,
          cy,
          radii[i],
          radii[i] * flatten,
          tilt,
          a,
          a,
          1,
        ).first;
        return _node(p, 0.018 + random() * 0.012, 0.5 + i * 0.05, i.toDouble());
      }(),
  ],
);

LineArtSpec starTrails(
  double cx,
  double cy,
  LumiereRng random,
  int count,
  double maxR,
) => LineArtSpec(
  <LinePath>[
    for (int i = 0; i < count; i++)
      () {
        final double r = maxR * (0.1 + random() * 0.9);
        final double a = random() * kTau;
        final double span = 0.4 + random() * 0.8;
        final double w = 0.0008 + random() * 0.0008;
        final double alpha = 0.25 + random() * 0.3;
        return LinePath(
          points: arcPoints(cx, cy, r, a, a + span, 24),
          width: w,
          alpha: alpha,
          delay: i / count * 0.4,
          span: 0.3,
        );
      }(),
  ],
  <LineNode>[_node((cx, cy), 0.03, 0.1)],
);

LineArtSpec sextant(double cx, double cy, double r) => mergeArt(<LineArtSpec>[
  LineArtSpec(
    <LinePath>[
      LinePath(
        points: arcPoints(cx, cy, r, math.pi * 0.33, math.pi * 0.67, 48),
        width: 0.002,
        alpha: 0.6,
      ),
      _seg(
        (cx, cy),
        (cx + math.cos(math.pi * 0.33) * r, cy + math.sin(math.pi * 0.33) * r),
        width: 0.0014,
        alpha: 0.5,
        delay: 0.1,
      ),
      _seg(
        (cx, cy),
        (cx + math.cos(math.pi * 0.67) * r, cy + math.sin(math.pi * 0.67) * r),
        width: 0.0014,
        alpha: 0.5,
        delay: 0.12,
      ),
      _seg(
        (cx, cy),
        (
          cx + math.cos(math.pi * 0.45) * r * 1.1,
          cy + math.sin(math.pi * 0.45) * r * 1.1,
        ),
        width: 0.001,
        alpha: 0.45,
        delay: 0.3,
        dash: (0.006, 0.006),
      ),
      _seg(
        (cx - r * 0.9, cy - r * 0.2),
        (cx + r * 0.2, cy - r * 0.05),
        width: 0.0009,
        alpha: 0.35,
        delay: 0.35,
        dash: (0.004, 0.006),
      ),
    ],
    <LineNode>[_node((cx, cy), 0.022, 0.3)],
  ),
  rays(
    cx,
    cy,
    r * 0.94,
    r,
    30,
    from: math.pi * 0.33,
    to: math.pi * 0.67,
    style: const ArtStyle(delay: 0.2, alpha: 0.4),
  ),
]);

LineArtSpec constellation(
  double aspect,
  LumiereRng random,
  int count,
  (double, double, double, double) region, {
  double delay = 0,
}) {
  final (double x0, double y0, double x1, double y1) = region;
  final List<Pt> stars = <Pt>[
    for (int i = 0; i < count; i++)
      ((x0 + random() * (x1 - x0)) * aspect, y0 + random() * (y1 - y0)),
  ]..sort((Pt a, Pt b) => a.$1.compareTo(b.$1));
  return LineArtSpec(
    <LinePath>[
      for (int i = 1; i < stars.length; i++)
        _seg(
          stars[i - 1],
          stars[i],
          width: 0.001,
          alpha: 0.4,
          delay: delay + 0.2 + (i - 1) * 0.06,
          span: 0.2,
        ),
    ],
    <LineNode>[
      for (int i = 0; i < stars.length; i++)
        _node(
          stars[i],
          0.018 + random() * 0.016,
          delay + i * 0.05,
          i.toDouble(),
        ),
    ],
  );
}

LineArtSpec corona(double cx, double cy, double r, LumiereRng random) =>
    LineArtSpec(
      <LinePath>[
        circle(cx, cy, r, const ArtStyle(width: 0.0024, alpha: 0.65)),
        for (int i = 0; i < 40; i++)
          () {
            final double a = i / 40 * kTau + random() * 0.05;
            final double len = r * (0.25 + random() * 0.9);
            final double alpha = 0.25 + random() * 0.3;
            return _seg(
              (cx + math.cos(a) * r * 1.05, cy + math.sin(a) * r * 1.05),
              (cx + math.cos(a) * (r + len), cy + math.sin(a) * (r + len)),
              width: 0.0008,
              alpha: alpha,
              delay: 0.2 + i / 40 * 0.3,
              span: 0.15,
            );
          }(),
      ],
      <LineNode>[_node((cx + r * 0.7, cy - r * 0.7), 0.03, 0.5)],
    );

LineArtSpec crescent(double cx, double cy, double r) => LineArtSpec(<LinePath>[
  LinePath(
    points: arcPoints(cx, cy, r, math.pi * 0.35, math.pi * 1.65, 60),
    width: 0.002,
    alpha: 0.6,
  ),
  LinePath(
    points: arcPoints(
      cx + r * 0.45,
      cy,
      r * 0.85,
      math.pi * 0.58,
      math.pi * 1.42,
      60,
    ),
    width: 0.0012,
    alpha: 0.4,
    delay: 0.15,
  ),
], const <LineNode>[]);

LineArtSpec armillary(double cx, double cy, double r) => LineArtSpec(
  <LinePath>[
    circle(cx, cy, r, const ArtStyle(width: 0.002, alpha: 0.55)),
    LinePath(
      points: ellipsePath(cx, cy, r, r * 0.3, 0),
      width: 0.0014,
      alpha: 0.45,
      delay: 0.1,
    ),
    LinePath(
      points: ellipsePath(cx, cy, r, r * 0.3, 0.41),
      width: 0.0014,
      alpha: 0.45,
      delay: 0.15,
    ),
    LinePath(
      points: ellipsePath(cx, cy, r * 0.3, r, 0),
      width: 0.0012,
      alpha: 0.4,
      delay: 0.2,
    ),
    _seg(
      (cx - math.sin(0.41) * r * 1.25, cy - math.cos(0.41) * r * 1.25),
      (cx + math.sin(0.41) * r * 1.25, cy + math.cos(0.41) * r * 1.25),
      width: 0.0012,
      alpha: 0.45,
      delay: 0.3,
    ),
  ],
  <LineNode>[_node((cx, cy), 0.03, 0.3)],
);

LineArtSpec meteors(double aspect, LumiereRng random, int count) {
  final List<LinePath> paths = <LinePath>[];
  final List<LineNode> nodes = <LineNode>[];
  for (int i = 0; i < count; i++) {
    final double x = (0.2 + random() * 0.8) * aspect;
    final double y = random() * 0.5;
    final double len = 0.12 + random() * 0.25;
    final Pt head = (x - len * 0.8, y + len * 0.6);
    paths.add(
      _seg(
        (x, y),
        head,
        width: 0.0012 + random() * 0.001,
        alpha: 0.45,
        delay: i * 0.08,
        span: 0.2,
      ),
    );
    nodes.add(_node(head, 0.02, i * 0.08 + 0.2, i.toDouble()));
  }
  return LineArtSpec(paths, nodes);
}

LineArtSpec lampHead(
  double x,
  double y,
  double angle,
  double size, {
  double delay = 0,
}) {
  final Pt d = (math.cos(angle), math.sin(angle));
  final Pt n = (-d.$2, d.$1);
  final Pt back = (x - d.$1 * size, y - d.$2 * size);
  final List<Pt> c = <Pt>[
    (back.$1 + n.$1 * size * 0.35, back.$2 + n.$2 * size * 0.35),
    (x + n.$1 * size * 0.6, y + n.$2 * size * 0.6),
    (x - n.$1 * size * 0.6, y - n.$2 * size * 0.6),
    (back.$1 - n.$1 * size * 0.35, back.$2 - n.$2 * size * 0.35),
  ];
  return LineArtSpec(<LinePath>[
    LinePath(
      points: <Pt>[...c, c.first],
      width: 0.0018,
      alpha: 0.55,
      span: 0.3,
      delay: delay,
    ),
  ], const <LineNode>[]);
}

LineArtSpec curtains(double aspect, double gap) => LineArtSpec(<LinePath>[
  for (final int side in <int>[-1, 1])
    for (int i = 0; i < 6; i++)
      LinePath(
        points: <Pt>[
          for (int k = 0; k <= 40; k++)
            (
              aspect / 2 +
                  side * (gap / 2 + i * 0.05) +
                  math.sin(k / 40 * 5 + i) * 0.008 * side,
              -0.02 + k / 40 * 1.04,
            ),
        ],
        width: 0.001 + (5 - i) * 0.0002,
        alpha: 0.2 + (5 - i) * 0.05,
        delay: i * 0.05,
        span: 0.5,
      ),
], const <LineNode>[]);

LineArtSpec projector(double x, double y, double size) => LineArtSpec(
  <LinePath>[
    _rect(x - size, y - size * 0.3, size, size * 0.6, _none, 0.0018, 0.55),
    circle(
      x - size * 0.75,
      y - size * 0.65,
      size * 0.33,
      const ArtStyle(width: 0.0014, alpha: 0.5, delay: 0.1),
    ),
    circle(
      x - size * 0.25,
      y - size * 0.65,
      size * 0.33,
      const ArtStyle(width: 0.0014, alpha: 0.5, delay: 0.15),
    ),
    LinePath(
      points: <Pt>[
        (x, y - size * 0.12),
        (x + size * 0.18, y - size * 0.18),
        (x + size * 0.18, y + size * 0.18),
        (x, y + size * 0.12),
      ],
      width: 0.0014,
      alpha: 0.5,
      delay: 0.2,
    ),
  ],
  <LineNode>[_node((x + size * 0.18, y), 0.024, 0.3)],
);

LineArtSpec horizon(double aspect, double y) => LineArtSpec(<LinePath>[
  _seg((0, y), (aspect, y), width: 0.0014, alpha: 0.4, span: 0.6),
  for (int i = 0; i < 16; i++)
    _seg(
      (aspect * (i + 0.5) / 16, y),
      (aspect * (i + 0.5) / 16, y + 0.012),
      width: 0.0008,
      alpha: 0.3,
      delay: 0.3 + i * 0.01,
      span: 0.08,
    ),
], const <LineNode>[]);
